// Screenmaps: each display config's last saved layout, drawn as a map of its displays
// and as bulleted lists. Data from stepper's lua/screenmaps.lua (see README.md):
//   /data/screenmaps-now.json      the current config, and when each config was saved
//   /data/screenmap-<config>.json  its displays, and its windows front to back
// A config with no screenmap yet (last used before screenmaps existed) is rebuilt from
// its /data/window-layout-<n>.json: no window ids, and only the displays that held a window.
'use strict';

const DATA = '/data/';
const ICONS = '/data/app-icons/';
const POLL_MS = 3000;
const GAP = 4;   // px between displays, which touch in macOS's coordinates
// layout.lua's names for the displays, the ones Lunar shows (positionNames)
const POSITIONS = {
  left: '←Left', top: '↑Top Center', center: '⊙Middle Center',
  bottom: '↓Bottom Center', right: 'Right→',
};
// A click brings the window forward through Hammerspoon, so only on the Mac itself
// (an iPad reports MacIntel too, but with touch points)
const ON_MAC = /Mac/.test(navigator.platform) && navigator.maxTouchPoints === 0;

const $ = id => document.getElementById(id);
const state = {
  now: null,        // screenmaps-now.json
  nowSig: '',
  maps: {},         // config name → {sig, map}
  appBundles: {},   // app name → bundle ID, from every map that has them
  chosen: null,     // the config picked by hand during this visit
  view: localStorage.getItem('screenmaps.view') === 'list' ? 'list' : 'map',
};

const list = v => (Array.isArray(v) ? v : []);   // hs.json.encode writes an empty table as {}

async function fetchJSON(path) {
  try {
    // ?raw=1: Caddy's F022 viewers answer a bare .json URL with their viewer page
    const res = await fetch(path + '?raw=1', {cache: 'no-store'});
    return res.ok ? await res.json() : null;
  } catch (e) {
    return null;
  }
}

// --- Data ---------------------------------------------------------------------

function fromScreenmap(doc) {
  return {
    name: doc.config, saved: doc.saved, rebuilt: false,
    displays: list(doc.displays), windows: list(doc.windows).filter(w => w.frame),
  };
}

// A layout save has no list of displays, but each entry carries its display's visible
// frame, so the displays that held a window can be rebuilt from those
function fromLayout(c, entries) {
  const displays = new Map();
  for (const e of entries) {
    const f = e.screenFrame;
    if (!f) continue;
    const key = e.screenPosition || `${f.x},${f.y}`;
    if (!displays.has(key)) displays.set(key, {position: e.screenPosition, full: f, frame: f});
  }
  return {
    name: c.name, saved: c.layoutSaved, rebuilt: true,
    displays: [...displays.values()],
    windows: entries.filter(e => e.frame).map(e => ({
      app: e.app, bundle: e.bundle, title: e.title || '', screen: e.screenPosition, frame: e.frame,
    })),
  };
}

async function loadMaps() {
  for (const c of list(state.now.configs)) {
    const sig = `${c.saved || ''}/${c.layoutSaved || ''}`;
    if (state.maps[c.name] && state.maps[c.name].sig === sig) continue;
    let map = null;
    if (c.saved) {
      const doc = await fetchJSON(`${DATA}screenmap-${c.name}.json`);
      if (doc) map = fromScreenmap(doc);
    }
    if (!map && c.layoutSaved) {
      const entries = await fetchJSON(`${DATA}window-layout-${c.screens}.json`);
      if (Array.isArray(entries)) map = fromLayout(c, entries);
    }
    state.maps[c.name] = {sig, map};
  }
  // Layout saves from before screenmaps have no bundle IDs: their apps borrow the icons
  // of the apps running now and of the newer maps
  Object.assign(state.appBundles, state.now.apps || {});
  for (const entry of Object.values(state.maps)) {
    for (const w of entry.map ? entry.map.windows : []) {
      if (w.bundle) state.appBundles[w.app] = w.bundle;
    }
  }
}

const bundleOf = w => w.bundle || state.appBundles[w.app];

// The config in use, unless that's the laptop alone: on the go, the desk layout you
// last left is the one worth seeing. A config picked by hand wins.
function shownConfig() {
  const has = name => state.maps[name] && state.maps[name].map;
  if (state.chosen && has(state.chosen)) return state.chosen;
  const configs = list(state.now.configs).filter(c => has(c.name));
  const current = configs.find(c => c.name === state.now.current);
  if (current && current.screens > 1) return current.name;
  const savedAt = c => state.maps[c.name].map.saved || 0;
  const desks = configs.filter(c => c.screens > 1).sort((a, b) => savedAt(b) - savedAt(a));
  if (desks.length) return desks[0].name;
  return current ? current.name : (configs[0] ? configs[0].name : null);
}

// The display a window was saved on: by its position name, else the nearest to its center
function displayOf(map, w) {
  if (w.screen) {
    const d = map.displays.find(d => d.position === w.screen);
    if (d) return d;
  }
  const cx = w.frame.x + w.frame.w / 2, cy = w.frame.y + w.frame.h / 2;
  let best = null, bestDist = Infinity;
  for (const d of map.displays) {
    const f = d.full;
    const dx = Math.max(f.x - cx, 0, cx - (f.x + f.w)), dy = Math.max(f.y - cy, 0, cy - (f.y + f.h));
    if (dx * dx + dy * dy < bestDist) { best = d; bestDist = dx * dx + dy * dy; }
  }
  return best;
}

// display → [{w, z}], front to back (z: place in the whole stack, 0 at the front)
function windowsByDisplay(map) {
  const by = new Map(map.displays.map(d => [d, []]));
  map.windows.forEach((w, z) => {
    const d = displayOf(map, w);
    if (d) by.get(d).push({w, z});
  });
  return by;
}

// --- Small helpers ---------------------------------------------------------------

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function hue(s) {
  let h = 0;
  for (const ch of String(s || '')) h = (h * 31 + ch.codePointAt(0)) % 360;
  return h;
}

function when(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000), now = new Date();
  const hm = d.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', hour12: false});
  if (d.toDateString() === now.toDateString()) return hm;
  return `${d.toLocaleDateString([], {month: 'short', day: 'numeric'})}, ${hm}`;
}

function shortWhen(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  if (d.toDateString() === new Date().toDateString()) {
    return d.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', hour12: false});
  }
  return d.toLocaleDateString([], {month: 'short', day: 'numeric'});
}

// "El reincidente - Google Chrome - Eli (Eli - main)" → "El reincidente"
function cleanTitle(w) {
  const t = w.title || '';
  const cut = t.indexOf(' - ' + w.app);
  const clean = (cut > 0 ? t.slice(0, cut) : t).trim();
  return clean || w.app;
}

function displayName(d) {
  return POSITIONS[d.position] || d.name || `${d.full.w}×${d.full.h}`;
}

function monitorText(d) {
  const parts = [];
  if (d.name) parts.push(d.name);
  parts.push(`${d.full.w}×${d.full.h}`);
  if (d.rotation) parts.push(`turned ${d.rotation}°`);
  return parts.join(' · ');
}

function isBuiltin(d) {
  return /Built-in/.test(d.name || '') || (!d.name && d.position === 'bottom');
}

function letterEl(w, cls) {
  const s = el('span', 'letter' + (cls ? ' ' + cls : ''), (w.app || '?').trim().charAt(0).toUpperCase());
  s.style.setProperty('--hue', hue(bundleOf(w) || w.app));
  return s;
}

function iconEl(w, cls) {
  const bundle = bundleOf(w);
  if (!bundle) return letterEl(w, cls);
  const img = el('img', cls);
  img.alt = '';
  img.src = ICONS + encodeURIComponent(bundle) + '.png';
  img.onerror = () => img.replaceWith(letterEl(w, cls));
  return img;
}

// --- Popup ------------------------------------------------------------------------

function showPop(map, w, z, ev, clickable) {
  const pop = $('pop');
  pop.textContent = '';
  const head = el('div', 'pop-title');
  head.append(iconEl(w), el('span', null, w.title || w.app));
  pop.append(head);
  const d = displayOf(map, w);
  pop.append(el('div', 'pop-line',
    `${w.app} · ${w.frame.w} × ${w.frame.h} on ${d ? displayName(d) : '?'}`));
  const notes = [];
  if (z === 0) notes.push('the front window');
  if (w.moved && w.seen && w.moved !== w.seen) {
    notes.push(`moved ${when(w.moved)}`, `first saved ${when(w.seen)}`);
  } else if (w.seen) {
    notes.push(`in place since ${when(w.seen)}`);
  }
  if (notes.length) pop.append(el('div', 'pop-line', notes.join(' · ')));
  if (clickable) pop.append(el('div', 'pop-line act', 'Click to bring it forward'));
  pop.hidden = false;
  movePop(ev);
}

function movePop(ev) {
  const pop = $('pop');
  if (pop.hidden) return;
  const pad = 14, r = pop.getBoundingClientRect();
  let x = ev.pageX + pad, y = ev.pageY + pad;
  if (ev.clientX + pad + r.width > window.innerWidth) x = ev.pageX - pad - r.width;
  if (ev.clientY + pad + r.height > window.innerHeight) y = ev.pageY - pad - r.height;
  pop.style.left = `${Math.max(4, x)}px`;
  pop.style.top = `${Math.max(4, y)}px`;
}

function hidePop() { $('pop').hidden = true; }

function withPop(node, map, w, z, clickable) {
  node.addEventListener('mouseenter', ev => showPop(map, w, z, ev, clickable));
  node.addEventListener('mousemove', movePop);
  node.addEventListener('mouseleave', hidePop);
}

// --- Map --------------------------------------------------------------------------

function renderMap(map, live) {
  const box = $('map');
  box.textContent = '';
  const ds = map.displays;
  if (!ds.length) {
    box.append(el('p', 'empty', 'No displays saved for this config.'));
    box.style.height = '';
    return;
  }
  const minX = Math.min(...ds.map(d => d.full.x)), minY = Math.min(...ds.map(d => d.full.y));
  const maxX = Math.max(...ds.map(d => d.full.x + d.full.w));
  const maxY = Math.max(...ds.map(d => d.full.y + d.full.h));
  const width = box.clientWidth || 1000;
  const room = window.innerHeight - box.getBoundingClientRect().top - 24;
  const scale = Math.min(width / (maxX - minX), Math.max(360, room) / (maxY - minY));
  const left = (width - (maxX - minX) * scale) / 2;   // centred when the height limits it
  box.style.height = `${Math.ceil((maxY - minY) * scale)}px`;

  const by = windowsByDisplay(map);
  const total = map.windows.length;
  for (const d of ds) {
    const de = el('div', 'display' + (isBuiltin(d) ? ' builtin' : ''));
    de.style.left = `${left + (d.full.x - minX) * scale + GAP / 2}px`;
    de.style.top = `${(d.full.y - minY) * scale + GAP / 2}px`;
    de.style.width = `${d.full.w * scale - GAP}px`;
    de.style.height = `${d.full.h * scale - GAP}px`;
    const bar = d.frame.y - d.full.y;   // the menu bar
    if (bar > 0) {
      const mb = el('div', 'menubar');
      mb.style.height = `${bar * scale}px`;
      de.append(mb);
    }
    const wins = by.get(d);
    wins.forEach(({w, z}, i) => {
      const clickable = live && w.id != null && ON_MAC;
      const we = el(clickable ? 'a' : 'div', 'win');
      if (clickable) we.href = `hammerspoon://screenmaps?focus=${w.id}`;
      if (z === 0) we.classList.add('focused');
      if (i === 0) we.classList.add('front');
      // Inside its display, which clips it the way macOS does
      we.style.left = `${(w.frame.x - d.full.x) * scale - GAP / 2}px`;
      we.style.top = `${(w.frame.y - d.full.y) * scale - GAP / 2}px`;
      we.style.width = `${w.frame.w * scale}px`;
      we.style.height = `${w.frame.h * scale}px`;
      we.style.zIndex = String(total - z);
      we.style.setProperty('--hue', hue(bundleOf(w) || w.app));
      if (w.frame.w * scale < 48 || w.frame.h * scale < 22) we.classList.add('tiny');
      const head = el('div', 'win-head');
      head.append(iconEl(w), el('span', 'win-title', cleanTitle(w)));
      we.append(head);
      // Big enough: its app's icon, faded, in the middle, to tell the apps apart at a glance
      if (w.frame.w * scale >= 70 && w.frame.h * scale >= 64) we.append(iconEl(w, 'win-mark'));
      withPop(we, map, w, z, clickable);
      de.append(we);
    });
    const label = el('div', 'display-label', displayName(d) + ' ');
    label.append(el('span', 'count', String(wins.length)));
    de.title = monitorText(d);
    de.append(label);
    box.append(de);
  }
}

// --- List -------------------------------------------------------------------------

function renderList(map, live) {
  const box = $('list');
  box.textContent = '';
  const by = windowsByDisplay(map);
  // Display by display: left to right, and in each column top to bottom
  const ds = [...map.displays].sort((a, b) => a.full.x - b.full.x || a.full.y - b.full.y);
  for (const d of ds) {
    const wins = by.get(d);
    const sec = el('section', 'screen-list');
    const h = el('h3', null, displayName(d) + ' ');
    h.append(el('span', 'count', String(wins.length)));
    sec.append(h, el('div', 'monitor', monitorText(d)));
    const ul = el('ul');
    for (const {w, z} of wins) {
      const li = el('li', z === 0 ? 'focused' : null);
      const clickable = live && w.id != null && ON_MAC;
      const title = el(clickable ? 'a' : 'span', null, cleanTitle(w));
      if (clickable) title.href = `hammerspoon://screenmaps?focus=${w.id}`;
      li.append(iconEl(w), title, ' ', el('span', 'app', w.app));
      withPop(li, map, w, z, clickable);
      ul.append(li);
    }
    if (!wins.length) ul.append(el('li', 'none', 'no windows'));
    sec.append(ul);
    box.append(sec);
  }
}

// --- Page ---------------------------------------------------------------------------

function renderConfigs(shown) {
  const nav = $('configs');
  nav.textContent = '';
  for (const c of list(state.now.configs)) {
    const entry = state.maps[c.name];
    if (!entry || !entry.map) continue;
    const current = c.name === state.now.current;
    const b = el('button', (c.name === shown ? 'active' : '') + (current ? ' current' : ''), c.name + ' ');
    b.type = 'button';
    b.title = `${c.screens} display${c.screens > 1 ? 's' : ''}${current ? ', in use now' : ''}`;
    b.append(el('span', 'when', shortWhen(entry.map.saved)));
    b.onclick = () => { state.chosen = c.name; render(); };
    nav.append(b);
  }
}

function render() {
  hidePop();
  const name = state.now && shownConfig();
  if (!name) {
    $('summary').textContent = 'No saved layouts yet.';
    return;
  }
  const map = state.maps[name].map;
  const live = name === state.now.current;
  renderConfigs(name);
  $('heading').textContent = `Screenmaps — ${name}`;
  document.title = `Screenmaps — ${name}`;
  $('asOf').textContent = map.saved ? `${live ? 'unchanged since' : 'last here'} ${when(map.saved)}` : '';
  const nd = map.displays.length;
  $('summary').textContent =
    `${map.windows.length} window${map.windows.length === 1 ? '' : 's'} on ${nd} display${nd === 1 ? '' : 's'}`;
  if (map.rebuilt) {
    $('summary').append(' · ', el('span', 'note',
      'rebuilt from its layout save, from before screenmaps: displays without windows are missing'));
  }
  $('panel').classList.toggle('show-list', state.view === 'list');
  for (const b of document.querySelectorAll('.panel-views button')) {
    b.classList.toggle('active', b.dataset.view === state.view);
  }
  const action = live && ON_MAC ? '; click one to bring it forward' : '';
  $('hint').textContent = state.view === 'map'
    ? `Each display where it sits, each window where it was; hover one for its title${action}`
    : `Each display's windows, front to back${action}`;
  if (state.view === 'map') renderMap(map, live);
  else renderList(map, live);
}

function setView(view) {
  state.view = view;
  localStorage.setItem('screenmaps.view', view);
  render();
}

async function refresh() {
  const now = await fetchJSON(DATA + 'screenmaps-now.json');
  if (!now || !Array.isArray(now.configs)) {
    if (!state.now) {
      $('summary').textContent = "No screenmaps yet: Hammerspoon writes them when stepper loads.";
    }
    return;
  }
  const sig = JSON.stringify(now);
  if (sig === state.nowSig) return;
  state.nowSig = sig;
  state.now = now;
  await loadMaps();
  render();
}

for (const b of document.querySelectorAll('.panel-views button')) {
  b.addEventListener('click', () => setView(b.dataset.view));
}
document.addEventListener('keydown', ev => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  if (ev.key === 'm') setView('map');
  else if (ev.key === 'l') setView('list');
  else if (ev.key === 'Escape') hidePop();
});
let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { if (state.now && state.view === 'map') render(); }, 150);
});
// Follow the saves while the page is in view
setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, POLL_MS);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') refresh();
});
refresh();
