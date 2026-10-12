// Screenmaps: each display config's last saved layout. The panel holds the map (each
// display at its real size, where it sits, and its windows where they were) or the days
// (the windows by the day they were opened, and by the day they were last used); below
// it, the list, a bulleted list per display, laid out as the displays stand. Data from
// stepper's lua/screenmaps.lua (see README.md):
//   /data/screenmaps-now.json      the current config, and when each config was saved
//   /data/screenmap-<config>.json  its displays, windows front to back, minimized windows
// A config with no screenmap yet is rebuilt from its /data/window-layout-<n>.json: no
// window ids or times, no sizes in millimetres, and only the displays that held a window.
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
// ⌘-click brings a window forward through Hammerspoon (hammerspoon://screenmaps?focus=),
// so only on the Mac itself (an iPad reports MacIntel too, but with touch points). A plain
// click did it until 2026-10-11, but lagged a little, and the map is for seeing what's
// where: forward is now the deliberate choice.
const ON_MAC = /Mac/.test(navigator.platform) && navigator.maxTouchPoints === 0;
const CAN_FOCUS = ON_MAC;
const TOUCH = navigator.maxTouchPoints > 0;   // free 3D's drags read the canvas there
// The live Chrome tablog (reading's F030/Chrome-tablogs now/chrome.jsonc), through a
// symlink in data/ so it's same-origin: its windows' tabs go on the map's Chrome windows
const CHROME_NOW = DATA + 'chrome-now.jsonc';
const FAVICONS = 'https://reading.internal/features/F030-tablogs/favicons/';

const $ = id => document.getElementById(id);
const state = {
  now: null,        // screenmaps-now.json
  nowSig: '',
  maps: {},         // config name → {sig, map}
  appBundles: {},   // app name → bundle ID, from the running apps and every map
  chosen: null,     // the config picked by hand during this visit
  view: localStorage.getItem('screenmaps.view') === 'days' ? 'days' : 'map',
  filter: null,     // {label, keys}: the windows a day or app in Days picked out
  chrome: null,     // the live Chrome tablog: {taken, windows}
  chromeSig: '',
  cams: {},         // config name → free 3D's camera (freeCam)
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

// The live Chrome tablog, comments stripped (it's JSONC: a few // lines on top)
async function fetchChrome() {
  try {
    const res = await fetch(CHROME_NOW + '?raw=1', {cache: 'no-store'});
    if (!res.ok) return null;
    const text = (await res.text()).split('\n').filter(l => !l.startsWith('//')).join('\n');
    return JSON.parse(text);
  } catch (e) {
    return null;
  }
}

// The live config's Chrome windows → their tabs in the tablog: the tablog window whose
// bounds (Chrome's session file, the same points as the saves) match the frame, else the
// one whose front tab's title the window's title starts with. Each tablog window once.
function chromeTabs(map) {
  const out = new Map();
  const tws = state.chrome ? list(state.chrome.windows).filter(t => !t.minimized && list(t.tabs).length) : [];
  const mine = map.windows.filter(w => w.app === 'Google Chrome' || w.bundle === 'com.google.Chrome');
  if (!tws.length || !mine.length) return out;
  const used = new Set();
  const pairs = [];
  for (const w of mine) {
    for (const t of tws) {
      if (!Array.isArray(t.bounds)) continue;
      const [x, y, bw, bh] = t.bounds, f = w.frame;
      const dist = Math.abs(x - f.x) + Math.abs(y - f.y) + Math.abs(bw - f.w) + Math.abs(bh - f.h);
      if (dist <= 40) pairs.push({w, t, dist});
    }
  }
  for (const {w, t} of pairs.sort((a, b) => a.dist - b.dist)) {
    if (out.has(w) || used.has(t)) continue;
    out.set(w, t.tabs);
    used.add(t);
  }
  for (const w of mine) {
    if (out.has(w)) continue;
    const title = cleanTitle(w);
    const t = tws.find(t => !used.has(t) && list(t.tabs).some(tab => tab.front && tab.title && title.startsWith(tab.title)));
    if (t) { out.set(w, t.tabs); used.add(t); }
  }
  return out;
}

function faviconEl(tab) {
  const img = el('img', 'tab-fav' + (tab.front ? ' front-tab' : ''));
  img.alt = '';
  img.loading = 'lazy';
  img.src = FAVICONS + encodeURIComponent(tab.fav || tab.root_domain || '') + '.png';
  img.onerror = () => {
    const s = el('span', 'tab-fav letter' + (tab.front ? ' front-tab' : ''), (tab.root_domain || '?').charAt(0).toUpperCase());
    s.style.setProperty('--hue', hue(tab.root_domain));
    img.replaceWith(s);
  };
  return img;
}

// Twins share a size: displays of one model ("LG HDR 4K (1)" and "(2)") at the same
// resolution are the same panel, but an EDID can misreport it. The Middle Center LG's says
// 598 × 341 mm, a 27″ panel, where its twin above says 702 × 400, the 32″ both are.
// The larger reading wins; mmReported keeps the one the display gave.
function twinSizes(displays) {
  const model = d => `${(d.name || '').replace(/\s*\(\d+\)$/, '')}|${[d.full.w, d.full.h].sort().join('x')}`;
  const area = mm => (mm ? mm.w * mm.h : 0);
  const biggest = new Map();
  for (const d of displays) {
    if (d.name && d.mm && area(d.mm) > area(biggest.get(model(d)))) biggest.set(model(d), d.mm);
  }
  return displays.map(d => {
    const mm = d.name && biggest.get(model(d));
    return mm && area(mm) > area(d.mm) ? {...d, mm, mmReported: d.mm} : d;
  });
}

function fromScreenmap(doc) {
  return {
    name: doc.config, saved: doc.saved, since: doc.since, rebuilt: false,
    displays: twinSizes(list(doc.displays)),
    windows: list(doc.windows).filter(w => w.frame),
    minimized: list(doc.minimized).filter(w => w.frame),
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
    minimized: [],
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
    if (!entry.map) continue;
    for (const w of [...entry.map.windows, ...entry.map.minimized]) {
      if (w.bundle) state.appBundles[w.app] = w.bundle;
    }
  }
}

const bundleOf = w => w.bundle || state.appBundles[w.app];
// A window's identity on the page, across the map, the days and the list
const keyOf = w => (w.id != null ? `id:${w.id}` : `at:${w.app}\n${w.title}`);
const screenId = d => d.position || `${d.full.x},${d.full.y}`;

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

const overlapX = (a, b) => Math.min(a.full.x + a.full.w, b.full.x + b.full.w) - Math.max(a.full.x, b.full.x) > 0;
const overlapY = (a, b) => Math.min(a.full.y + a.full.h, b.full.y + b.full.h) - Math.max(a.full.y, b.full.y) > 0;

// Each display at its real size (its EDID's millimetres), arranged as macOS arranges them:
// centres placed from the arrangement, then each display pushed against the ones it
// touches in macOS, left to right and top to bottom, so a 37″ panel beside 32″ ones
// neither overlaps them nor leaves a gap. Displays without a size keep their points.
function physicalRects(displays) {
  const ratios = displays.filter(d => d.mm).map(d => d.mm.w / d.full.w).sort((a, b) => a - b);
  const k = ratios.length ? ratios[Math.floor(ratios.length / 2)] : 1;   // mm per point
  const rects = new Map();
  for (const d of displays) {
    const w = d.mm ? d.mm.w : d.full.w * k, h = d.mm ? d.mm.h : d.full.h * k;
    const cx = (d.full.x + d.full.w / 2) * k, cy = (d.full.y + d.full.h / 2) * k;
    rects.set(d, {x: cx - w / 2, y: cy - h / 2, w, h});
  }
  const TOL = 2;
  for (const b of [...displays].sort((p, q) => p.full.x - q.full.x)) {
    const lefts = displays.filter(a => a !== b && Math.abs(a.full.x + a.full.w - b.full.x) <= TOL && overlapY(a, b));
    if (lefts.length) rects.get(b).x = Math.max(...lefts.map(a => rects.get(a).x + rects.get(a).w));
  }
  for (const b of [...displays].sort((p, q) => p.full.y - q.full.y)) {
    const aboves = displays.filter(a => a !== b && Math.abs(a.full.y + a.full.h - b.full.y) <= TOL && overlapX(a, b));
    if (aboves.length) rects.get(b).y = Math.max(...aboves.map(a => rects.get(a).y + rects.get(a).h));
  }
  // The laptop sits centred under the display above it. macOS has it at that display's
  // left edge only so the pointer crosses where it should; on the desk it's in the middle.
  for (const b of displays.filter(isBuiltin)) {
    const aboves = displays.filter(a => a !== b && Math.abs(a.full.y + a.full.h - b.full.y) <= TOL && overlapX(a, b));
    if (aboves.length !== 1) continue;
    const a = rects.get(aboves[0]), r = rects.get(b);
    r.x = a.x + (a.w - r.w) / 2;
  }
  // Every column stands on the desk: its lowest display's bottom on the one line of the
  // lowest of all (the laptop's, on the desk). macOS's arrangement puts a side display as
  // high as it was dragged in System Settings, which on the page left Left, Bottom Center
  // and Right each ending at a height of its own (2026-10-11).
  const cols = displayColumns(displays);
  const bottom = d => rects.get(d).y + rects.get(d).h;
  const desk = Math.max(...displays.map(bottom));
  for (const c of cols) {
    const dy = desk - Math.max(...c.map(bottom));
    for (const d of c) rects.get(d).y += dy;
  }
  return rects;
}

// Columns as the displays stand: displays that overlap horizontally share a column, top
// to bottom; the columns run left to right
function displayColumns(displays) {
  const cols = [];
  for (const d of [...displays].sort((a, b) => a.full.x - b.full.x)) {
    const col = cols.find(c => c.some(o => overlapX(o, d)));
    if (col) col.push(d);
    else cols.push([d]);
  }
  for (const c of cols) c.sort((a, b) => a.full.y - b.full.y);
  return cols;
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

const hm = d => d.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', hour12: false});
const sameDay = (a, b) => a.toDateString() === b.toDateString();

function when(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  if (sameDay(d, new Date())) return hm(d);
  return `${d.toLocaleDateString([], {month: 'short', day: 'numeric'})}, ${hm(d)}`;
}

function shortWhen(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  return sameDay(d, new Date()) ? hm(d) : d.toLocaleDateString([], {month: 'short', day: 'numeric'});
}

// "Fri Oct 9", as the tablogs' days
function dayLabel(ts) {
  const d = new Date(ts * 1000);
  return `${d.toLocaleDateString([], {weekday: 'short'})} ${d.toLocaleDateString([], {month: 'short'})} ${d.getDate()}`;
}

function dayStart(ts) {
  const d = new Date(ts * 1000);
  d.setHours(0, 0, 0, 0);
  return d.getTime() / 1000;
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

const inches = d => (d.mm ? `${Math.round(Math.hypot(d.mm.w, d.mm.h) / 25.4)}″` : '');

function monitorText(d) {
  const parts = [];
  if (d.name) parts.push(d.name);
  if (d.mm) parts.push(`${inches(d)} (${d.mm.w} × ${d.mm.h} mm)`);
  if (d.mmReported) parts.push(`its EDID says ${d.mmReported.w} × ${d.mmReported.h} mm`);
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

// A window of the config in use, on the Mac, comes forward on ⌘-click (a minimized one
// back from the Dock): its node, on the map or in the list, carries data-focus
function focusable(node, w, live) {
  if (live && w.id != null && CAN_FOCUS) node.dataset.focus = String(w.id);
}

function initFocusClicks() {
  document.addEventListener('click', ev => {
    const node = ev.metaKey && ev.target.closest('[data-focus]');
    if (!node) return;
    ev.preventDefault();
    location.href = `hammerspoon://screenmaps?focus=${node.dataset.focus}`;
  });
}

function titleEl(w, live, cls) {
  const t = el('span', 'title' + (cls ? ' ' + cls : ''), cleanTitle(w));
  focusable(t, w, live);
  return t;
}

// The app's name after a window in the list, a toggle: only its windows, on the map and
// in the list, the rest dimmed (the app filters' filter, which it lights too)
function appToggle(map, w, text) {
  const b = el('button', 'app', text || w.app);
  b.type = 'button';
  b.dataset.filter = w.app;
  b.title = `Only ${w.app}'s windows (click again for all)`;
  b.onclick = () => setFilter(w.app, [...map.windows, ...map.minimized].filter(o => o.app === w.app).map(keyOf), {mark: false});
  return b;
}

// --- Popup ------------------------------------------------------------------------

function showPop(nodes, ev) {
  const pop = $('pop');
  pop.textContent = '';
  pop.append(...nodes);
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

function onHover(node, build) {
  node.addEventListener('mouseenter', ev => showPop(build(), ev));
  node.addEventListener('mousemove', movePop);
  node.addEventListener('mouseleave', hidePop);
}

// A window's popup: its whole title, app, size and display, and its times
function windowPop(map, w, z, live, tabs) {
  const head = el('div', 'pop-title');
  head.append(iconEl(w), el('span', null, w.title || w.app));
  const nodes = [head];
  const d = displayOf(map, w);
  const where = d ? displayName(d) : '?';
  nodes.push(el('div', 'pop-line', z == null
    ? `${w.app} · ${w.frame.w} × ${w.frame.h} · minimized, from ${where}`
    : `${w.app} · ${w.frame.w} × ${w.frame.h} on ${where}`));
  const notes = [];
  if (z === 0) notes.push('the front window');
  if (w.seen) {
    notes.push(map.since && w.seen <= map.since ? `open before ${when(map.since)}` : `opened ${when(w.seen)}`);
  }
  if (w.moved && w.seen && w.moved > w.seen) notes.push(`moved ${when(w.moved)}`);
  if (w.used) notes.push(`last used ${when(w.used)}`);
  if (notes.length) nodes.push(el('div', 'pop-line', notes.join(' · ')));
  if (tabs && tabs.length) {   // a Chrome window's tabs, from the live tablog
    const ul = el('ul', 'pop-list pop-tabs');   // each tab with its favicon for a bullet
    for (const t of tabs.slice(0, 10)) {
      const li = el('li', t.front ? 'front-tab' : null);
      li.append(faviconEl(t), el('span', null, t.title || t.url));
      ul.append(li);
    }
    if (tabs.length > 10) ul.append(el('li', null, `and ${tabs.length - 10} more`));
    nodes.push(el('div', 'pop-line', `${tabs.length} tab${tabs.length === 1 ? '' : 's'}`), ul);
  }
  if (live && w.id != null && CAN_FOCUS) {
    nodes.push(el('div', 'pop-line act', z == null ? '⌘-click to bring it back from the Dock' : '⌘-click to bring it forward'));
  }
  return nodes;
}

// --- Filter: the windows a day or an app in Days, or an app filter, picked out ---------

// mark: false only dims the rest (the app filters), without outlining the picked windows
function setFilter(label, keys, {mark = true} = {}) {
  state.filter = state.filter && state.filter.label === label ? null : {label, keys: new Set(keys), mark};
  applyFilter();
}

function applyFilter() {
  const f = state.filter;
  const banner = $('banner');
  banner.hidden = !f;
  banner.textContent = '';
  if (f) {
    banner.append(el('span', null, `${f.label} · ${f.keys.size} window${f.keys.size === 1 ? '' : 's'}`));
    const clear = el('button', 'banner-clear', 'Show all (Esc)');
    clear.type = 'button';
    clear.onclick = () => { state.filter = null; applyFilter(); };
    banner.append(clear);
  }
  for (const node of document.querySelectorAll('[data-key]')) {
    const hit = !!f && f.keys.has(node.dataset.key);
    node.classList.toggle('dim', !!f && !hit);
    node.classList.toggle('hit', hit && f.mark);
  }
  for (const node of document.querySelectorAll('[data-filter]')) {
    node.classList.toggle('active', !!f && node.dataset.filter === f.label);
  }
}

// --- Map and list together -----------------------------------------------------------

// A window's node, on the map or in the list: its key, its app and its display
function tagWindow(node, w, d) {
  node.dataset.key = keyOf(w);
  node.dataset.app = w.app || '';
  if (d) node.dataset.on = screenId(d);
}

// Hovering a window, on the map or in the list, lights it in both (lit), its display
// on the map and its section in the list (near), and, a moment later, every other
// window of its app (kin: the slow fade is screenmaps.css's). The window comes to the top
// (raise): face on at once, as a flat map's would; turned only while ⌘ is held.
let hovered = null;
let cmdHeld = false;
function hoverWindow(node) {
  const key = node ? node.dataset.key : null;
  if (key === hovered) return;
  hovered = key;
  raise(false);
  for (const n of document.querySelectorAll('.lit, .kin, .near')) n.classList.remove('lit', 'kin', 'near');
  if (!node) return;
  const {app, on} = node.dataset;
  for (const n of document.querySelectorAll('#map [data-key], #list [data-key]')) {
    if (n.dataset.key === key) n.classList.add('lit');
    else if (app && n.dataset.app === app) n.classList.add('kin');
  }
  if (on) {
    for (const n of document.querySelectorAll('[data-screen]')) {
      if (n.dataset.screen === on) n.classList.add('near');
    }
  }
  raise(raising());
}

const raising = () => cmdHeld || !!(state.fly && faceOn(state.fly.cam));

// The hovered window comes in front of every other, without the ones in front of it
// fading. It slides straight toward you, along the line of sight: the views
// have no perspective, so it stays exactly where it was on screen, under the pointer, and
// only the depth order changes. The line of sight in the plane's own coordinates is the
// plane's rotation undone on the screen's z; far enough is past the whole scene.
function raise(on) {
  for (const w of document.querySelectorAll('#map .three-d .win.raised')) {
    w.classList.remove('raised');
    w.style.transform = w.dataset.z;
  }
  if (!on) return;
  for (const w of document.querySelectorAll('#map .three-d .win.lit')) {
    const plane = w.closest('.plane');
    const sight = new DOMMatrix(getComputedStyle(plane).transform).inverse().transformPoint(new DOMPoint(0, 0, 1, 0));
    const far = 2 * (plane.offsetWidth + plane.offsetHeight) / Math.hypot(sight.x, sight.y, sight.z);
    w.classList.add('raised');
    w.style.transform = `${w.dataset.z} translate3d(${sight.x * far}px, ${sight.y * far}px, ${sight.z * far}px)`;
  }
}

function initHoverLinks() {
  document.addEventListener('mouseover', ev => {
    cmdHeld = ev.metaKey;
    hoverWindow(ev.target.closest('#map [data-key], #list [data-key]'));
  });
  document.documentElement.addEventListener('mouseleave', () => hoverWindow(null));
  // ⌘ pressed or let go over a window raises it or puts it back
  const cmd = ev => {
    if (ev.key !== 'Meta' || ev.metaKey === cmdHeld) return;
    cmdHeld = ev.metaKey;
    raise(raising());
  };
  document.addEventListener('keydown', cmd);
  document.addEventListener('keyup', cmd);
  window.addEventListener('blur', () => { cmdHeld = false; raise(false); });
}

// The apps with several windows, most first, in the map's top-right corner: a click dims
// every other window, on the map and in the list
function renderAppFilters(map) {
  const box = $('apps');
  box.textContent = '';
  const byApp = new Map();
  for (const w of [...map.windows, ...map.minimized]) {
    if (!byApp.has(w.app)) byApp.set(w.app, []);
    byApp.get(w.app).push(w);
  }
  const apps = [...byApp.entries()].filter(([, ws]) => ws.length > 1).sort((a, b) => b[1].length - a[1].length);
  for (const [app, ws] of apps) {
    const b = el('button', 'app-filter');
    b.type = 'button';
    b.dataset.filter = app;
    b.title = `Only ${app}'s ${ws.length} windows`;
    b.append(iconEl(ws[0]), el('span', null, String(ws.length)));
    b.onclick = () => setFilter(app, ws.map(keyOf), {mark: false});
    box.append(b);
  }
}

// --- Map --------------------------------------------------------------------------

// The map is one scene under a camera you turn by dragging, zoom by pinching and pan by
// right-dragging, its angles from three presets, the panel's Flat | Turned | On the
// ground: face on, looking just like a flat map (Flat), the plane upright and turned
// (Turned), or lying on the ground (On the ground). yaw turns the scene about the
// vertical, pitch tilts it toward you (negative: seen from above). Until 2026-10-11 the
// panel had Flat | 3D | Free 3D, three renderers; the camera's face-on view replaced the
// flat one, its Turned the 3D one.
const PRESETS = {
  flat: {label: 'Flat', base: 'upright', yaw: 0, pitch: 0},
  turned: {label: 'Turned', base: 'upright', yaw: 42, pitch: -12},
  ground: {label: 'On the ground', base: 'ground', yaw: 26, pitch: -40},
};

// The preset picked, per config: Turned for the laptop alone, whose mostly maximized
// windows hide each other face on; Flat elsewhere
function presetOf(name) {
  let picked = null;
  try { picked = localStorage.getItem(`screenmaps.preset.${name}`); } catch (e) { picked = null; }
  if (PRESETS[picked]) return picked;
  const c = list(state.now.configs).find(c => c.name === name);
  return c && c.screens === 1 ? 'turned' : 'flat';
}

function setPreset(key) {
  const name = state.now && shownConfig();
  if (!name || !PRESETS[key]) return;
  try { localStorage.setItem(`screenmaps.preset.${name}`, key); } catch (e) { /* lasts the visit */ }
  delete state.cams[name];
  render();
}

// Windows stacked up from their display, the front one nearest you (Above), or sunk
// into it (Below): each display a see-through hole as deep as its windows, the front one
// just under its face. Kept for every config.
function stackOf() {
  try { return localStorage.getItem('screenmaps.stack') === 'below' ? 'below' : 'above'; } catch (e) { return 'above'; }
}

function setStack(dir) {
  try { localStorage.setItem('screenmaps.stack', dir); } catch (e) { /* lasts the visit */ }
  render();
}

// The shown config's camera: its preset's angles, then wherever you turn it, for the visit
function freeCam(name) {
  if (!state.cams[name]) {
    const key = presetOf(name), p = PRESETS[key];
    state.cams[name] = {preset: key, base: p.base, yaw: p.yaw, pitch: p.pitch, zoom: 1, panX: 0, panY: 0, fit: null};
  }
  return state.cams[name];
}

const faceOn = cam => cam.yaw === 0 && cam.pitch === 0 && cam.base === 'upright';

// How turned the camera is, 0 face on to 1 at 20° and past: the windows go from see-through
// to solid as it turns, the labels sink from above the stacks to their displays, and the
// holes' floors fade (screenmaps.css's --solid). Seen from behind counts as turned: a
// floor between you and its windows lets them through.
function solidity(cam) {
  const facing = new DOMMatrix(camTransform(cam)).m33;   // the plane's normal toward you, -1 from behind
  return Math.min(1, Math.acos(Math.max(-1, Math.min(1, facing))) * 180 / Math.PI / 20).toFixed(3);
}

// How far you're looking from behind the plane, 0 in front to 1 once past edge on (the
// plane's normal from 0.15 toward you to 0.15 away): from behind, the display surfaces
// stand in front of every window stacked above them, so they fade to their outlines
// (screenmaps.css's --behind)
function behindness(cam) {
  const facing = new DOMMatrix(camTransform(cam)).m33;
  return Math.max(0, Math.min(1, (0.15 - facing) / 0.3)).toFixed(3);
}

// The line of sight in the plane's own coordinates, scaled to one px of depth (--sight-x,
// --sight-y): a display's label lifted along it stays where it is on screen, as raise()'s
// windows do. Until 2026-10-12 it rose straight off the plane, and drifted sideways and
// back over the first 20° of a turn. Past 20° it sits on its display and needs none.
function setCamVars(stage, cam) {
  stage.style.setProperty('--solid', solidity(cam));
  stage.style.setProperty('--behind', behindness(cam));
  const sight = new DOMMatrix(camTransform(cam)).inverse().transformPoint(new DOMPoint(0, 0, 1, 0));
  const ok = Math.abs(sight.z) > 0.1;
  stage.style.setProperty('--sight-x', ok ? (sight.x / sight.z).toFixed(4) : '0');
  stage.style.setProperty('--sight-y', ok ? (sight.y / sight.z).toFixed(4) : '0');
}

// The plane's transform: the camera's tilt and turn, after laying the plane down for the
// ground (its top edge away from you, the stacks' depth pointing up)
const camTransform = cam => `rotateX(${cam.pitch}deg) rotateY(${cam.yaw}deg)` + (cam.base === 'ground' ? ' rotateX(90deg)' : '');

// A display sunk in (Below): see-through walls as deep as its windows and a floor under the
// back one, its face left open
function holeParts(depth) {
  const parts = [];
  for (const side of ['left', 'right', 'top', 'bottom']) {
    const wall = el('div', `hole-wall ${side}`);
    wall.style.setProperty('--deep', `${depth}px`);
    parts.push(wall);
  }
  const floor = el('div', 'hole-floor');
  floor.style.transform = `translateZ(${-depth}px)`;
  parts.push(floor);
  return parts;
}

// The map's displays and windows sit on a plane under the camera, each window one layer
// in front of the one behind it on its display (the stack the saves record front to back),
// or one layer below it when they're sunk in. The scene is a flat map's, at its size: face
// on, it is one.
function renderMap(map, live, name) {
  const box = $('map');
  box.textContent = '';
  const ds = map.displays;
  if (!ds.length) {
    box.append(el('p', 'empty', 'No displays saved for this config.'));
    return;
  }
  const cam = freeCam(name);
  const ground = cam.base === 'ground';
  const below = stackOf() === 'below';
  const rects = physicalRects(ds);
  const rs = [...rects.values()];
  const minX = Math.min(...rs.map(r => r.x)), minY = Math.min(...rs.map(r => r.y));
  const maxX = Math.max(...rs.map(r => r.x + r.w)), maxY = Math.max(...rs.map(r => r.y + r.h));
  // The canvas runs the viewport's whole width, out past the panel's sides; the scene fills
  // the panel's width, or the room
  const panelWidth = box.clientWidth || 1000;
  const width = document.documentElement.clientWidth;
  const room = Math.max(320, window.innerHeight * 0.68);
  const by = windowsByDisplay(map);
  const total = map.windows.length;
  const tabsOf = live ? chromeTabs(map) : new Map();
  // Layers wide apart, closer in a tall stack; on the ground closer still, or the stacks
  // float off it. The displays stay side by side as on the desk, a stack running into the
  // next display's (until 2026-10-11 the 3D view moved each column right by the stacks before it).
  const tallest = Math.max(1, ...[...by.values()].map(wins => wins.length));
  const layer = Math.max(24, Math.min(72, 640 / tallest)) * (ground ? 0.35 : 1);
  const scale = Math.min(panelWidth / (maxX - minX), room / (maxY - minY));
  const planeHeight = Math.ceil((maxY - minY) * scale);
  const planeWidth = Math.ceil((maxX - minX) * scale);
  const stage = el('div', 'map-stage three-d free' + (below ? ' below' : ''));
  const fit = el('div', 'fit');
  const plane = el('div', 'plane');
  plane.style.width = `${planeWidth}px`;
  plane.style.height = `${planeHeight}px`;
  plane.style.transform = camTransform(cam);
  setCamVars(stage, cam);
  fit.append(plane);
  stage.append(fit);
  stage.style.height = `${freeHeight() || Math.round(room)}px`;
  box.append(stage);
  stage.style.width = `${width}px`;
  const inset = Math.round(box.getBoundingClientRect().left);
  stage.style.marginLeft = `${-inset}px`;
  stage.style.setProperty('--inset', `${inset}px`);   // its flight label stays over the panel's edge

  for (const d of ds) {
    const r = rects.get(d);
    const sx = (r.w / d.full.w) * scale, sy = (r.h / d.full.h) * scale;   // px per point here
    const wins = by.get(d);
    const de = el('div', 'display' + (isBuiltin(d) ? ' builtin' : '') + (below && wins.length ? ' hole' : ''));
    de.dataset.screen = screenId(d);
    de.style.left = `${(r.x - minX) * scale + GAP / 2}px`;
    de.style.top = `${(r.y - minY) * scale + GAP / 2}px`;
    de.style.width = `${r.w * scale - GAP}px`;
    de.style.height = `${r.h * scale - GAP}px`;
    if (below && wins.length) de.append(...holeParts((wins.length + 1) * layer));
    const bar = d.frame.y - d.full.y;   // the menu bar
    if (bar > 0) {
      const mb = el('div', 'menubar');
      mb.style.height = `${bar * sy}px`;
      de.append(mb);
    }
    wins.forEach(({w, z}, i) => {
      const we = el('div', 'win');
      focusable(we, w, live);
      tagWindow(we, w, d);
      we.dataset.rank = String(i);   // its place in its display's stack, 0 at the front
      if (z === 0) we.classList.add('focused');
      if (i === 0) we.classList.add('front');
      const ww = w.frame.w * sx, wh = w.frame.h * sy;
      const wl = (w.frame.x - d.full.x) * sx - GAP / 2, wt = (w.frame.y - d.full.y) * sy - GAP / 2;
      we.style.left = `${wl}px`;
      we.style.top = `${wt}px`;
      we.style.width = `${ww}px`;
      we.style.height = `${wh}px`;
      we.style.zIndex = String(total - z);
      we.style.setProperty('--hue', hue(bundleOf(w) || w.app));
      if (ww < 48 || wh < 22) we.classList.add('tiny');
      const head = el('div', 'win-head');
      head.append(iconEl(w), el('span', 'win-title', cleanTitle(w)));
      we.append(head);
      const tabs = tabsOf.get(w);
      if (tabs && ww >= 48 && wh >= 48) {
        // A Chrome window: its logo on top, a rule, and its tabs' favicons in tab order
        const body = el('div', 'win-tabs');
        body.append(iconEl(w, 'win-logo'), el('hr'));
        const favs = el('div', 'tab-favs');
        for (const t of tabs) favs.append(faviconEl(t));
        body.append(favs);
        we.append(body);
      } else if (ww >= 70 && wh >= 64) {
        // Big enough: its app's icon, faded, in the middle, to tell the apps apart at a glance
        we.append(iconEl(w, 'win-mark'));
      }
      onHover(we, () => windowPop(map, w, z, live, tabs));
      de.append(we);
      // The front window nearest you: above, the top of the pile; below, just under the face
      we.dataset.z = `translateZ(${below ? -(i + 1) * layer : (wins.length - i) * layer}px)`;   // raise() adds to it
      we.style.transform = we.dataset.z;
    });
    const label = el('div', 'display-label', displayName(d));
    if (d.mm) label.append(el('span', 'size', ` ${inches(d)}`));
    label.append(el('span', 'count', ` · ${wins.length}`));
    // face on, above the pile, as a flat map's labels are above its windows; it sinks to its
    // display as you turn (below, the windows are under the face already)
    if (!below) label.style.setProperty('--lift', `${(wins.length + 1) * layer}px`);
    de.append(label);
    plane.append(de);
  }
  // the canvas's height left out: setting it keeps the scene's size (initFreeResize)
  const key = `${width}:${planeWidth}x${planeHeight}:${cam.base}:${below}`;
  if (!cam.fit || cam.fit.key !== key) cam.fit = {key, ...measureFit(stage, fit, width, stage.clientHeight, faceOn(cam))};
  applyView(fit, cam);
  stage.append(el('div', 'free-where'));
  initFreeDrag(stage, fit, plane, name, cam);
  initFreeResize(stage, fit, cam);
  // Tab's stops: all the displays, then each as the list reads them
  const order = displayColumns(ds).flat();
  state.fly = {stage, fit, cam, stops: [
    {label: 'All displays', nodes: () => [...stage.querySelectorAll('.display, .win')]},
    ...order.map(d => {
      const de = [...stage.querySelectorAll('.display')].find(n => n.dataset.screen === screenId(d));
      return {label: displayName(d), nodes: () => [de, ...de.querySelectorAll('.win')]};
    }),
  ], boxes: null};
  if (cam.stop != null) showStop(cam.stop);

  // The minimized windows after a rule, as the tablogs show minimized Chrome windows
  if (map.minimized.length) {
    box.append(el('div', 'map-divider', `Minimized windows · ${map.minimized.length}`));
    const strip = el('div', 'min-strip');
    for (const w of map.minimized) {
      const chip = el('div', 'min-chip');
      focusable(chip, w, live);
      tagWindow(chip, w);
      chip.style.setProperty('--hue', hue(bundleOf(w) || w.app));
      chip.append(iconEl(w), el('span', 'min-title', cleanTitle(w)));
      onHover(chip, () => windowPop(map, w, null, live));
      strip.append(chip);
    }
    box.append(strip);
  }
}

// What the plane's displays and windows cover on screen, relative to the stage, with the
// fit wrapper untransformed
function projectedBox(stage, fit) {
  fit.style.transform = '';
  const sr = stage.getBoundingClientRect();
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const n of stage.querySelectorAll('.display, .win')) {
    const r = n.getBoundingClientRect();
    x0 = Math.min(x0, r.left - sr.left);
    y0 = Math.min(y0, r.top - sr.top);
    x1 = Math.max(x1, r.right - sr.left);
    y1 = Math.max(y1, r.bottom - sr.top);
  }
  return {x0, y0, w: x1 - x0, h: y1 - y0};
}

// The scale and offset that centre the scene in the stage at its preset's angles; kept
// while you turn it, so turning doesn't pump the zoom. Face on it keeps a flat map's size,
// shrinking only if the canvas is too small for it.
function measureFit(stage, fit, width, height, flat) {
  const {x0, y0, w, h} = projectedBox(stage, fit);
  if (!(w > 0 && h > 0)) return {tx: 0, ty: 0, s: 1};
  const s = flat ? Math.min(1, width / w, height / h) : Math.min(width / w, height / h) * 0.9;
  return {tx: (width - w * s) / 2 - x0 * s, ty: (height - h * s) / 2 - y0 * s, s};
}

// Your pan and zoom on top of the fit
function applyView(fit, cam) {
  const f = cam.fit || {tx: 0, ty: 0, s: 1};
  fit.style.transform = `translate(${cam.panX}px, ${cam.panY}px) scale(${cam.zoom}) ` +
    `translate(${f.tx}px, ${f.ty}px) scale(${f.s})`;
}

// Zoom by k about a point of the stage, which stays put
function zoomAt(fit, cam, k, x, y) {
  const z = Math.min(8, Math.max(0.2, cam.zoom * k));
  const r = z / cam.zoom;
  cam.panX = x - r * (x - cam.panX);
  cam.panY = y - r * (y - cam.panY);
  cam.zoom = z;
  applyView(fit, cam);
}

// The panel's map controls: the presets lit for the camera at one, the stack's direction,
// and how to move the camera
function renderMapControls(name) {
  const cam = freeCam(name);
  for (const b of document.querySelectorAll('#presets button')) {
    const p = PRESETS[b.dataset.preset];
    b.classList.toggle('active', b.dataset.preset === cam.preset && cam.yaw === p.yaw && cam.pitch === p.pitch);
  }
  for (const b of document.querySelectorAll('#stack button')) {
    b.classList.toggle('active', b.dataset.stack === stackOf());
  }
  $('mapHint').textContent = (TOUCH
    ? 'drag a display to turn · drag around them to pan · pinch to zoom'
    : 'drag to turn · right-drag to pan · pinch to zoom · ⌘ raises a window') + ' · tab flies display to display';
}

// Free 3D's hands: a drag turns the scene, a right drag pans it (a ⌃ or ⇧ drag too); on
// a touch screen, where there's no right drag, a finger on a display or a window turns it
// and one on the canvas around them pans. A trackpad pinch (a ⌃-wheel to the browser, or
// Safari's gesture events) or two fingers on a touch screen zoom it. A plain wheel still
// scrolls the page; ⌘-click a window to bring it forward.
function initFreeDrag(stage, fit, plane, name, cam) {
  const pointers = new Map();
  let mode = null, last = null, pinch = null;
  const at = ev => {
    const r = stage.getBoundingClientRect();
    return {x: ev.clientX - r.left, y: ev.clientY - r.top};
  };
  const twoFingers = () => {
    const [a, b] = [...pointers.values()];
    return {d: Math.hypot(a.x - b.x, a.y - b.y), x: (a.x + b.x) / 2, y: (a.y + b.y) / 2};
  };
  stage.addEventListener('contextmenu', ev => ev.preventDefault());   // ⌃-click is a right click
  stage.addEventListener('pointerdown', ev => {
    if (ev.metaKey && ev.target.closest('[data-focus]')) return;   // ⌘-click: initFocusClicks
    hidePop();
    try { stage.setPointerCapture(ev.pointerId); } catch (e) { /* a synthetic pointer */ }
    pointers.set(ev.pointerId, at(ev));
    if (pointers.size === 2) {
      mode = 'pinch';
      pinch = twoFingers();
    } else {
      const offScene = ev.pointerType !== 'mouse' && !ev.target.closest('.display, .win');
      mode = ev.ctrlKey || ev.shiftKey || ev.button === 2 || offScene ? 'pan' : 'turn';
      last = at(ev);
    }
    stage.classList.add('dragging');
    landFlight(fit);
    ev.preventDefault();
  });
  stage.addEventListener('pointermove', ev => {
    if (!pointers.has(ev.pointerId)) return;
    const p = at(ev);
    pointers.set(ev.pointerId, p);
    if (mode === 'pinch' && pointers.size === 2) {
      const now = twoFingers();
      cam.panX += now.x - pinch.x;
      cam.panY += now.y - pinch.y;
      zoomAt(fit, cam, now.d / pinch.d, now.x, now.y);
      pinch = now;
    } else if (mode === 'turn') {
      cam.yaw += (p.x - last.x) * 0.35;
      cam.pitch = Math.max(-90, Math.min(90, cam.pitch - (p.y - last.y) * 0.35));
      plane.style.transform = camTransform(cam);
      setCamVars(stage, cam);
      raise(raising());   // the line of sight turned with it
      if (state.fly) state.fly.boxes = null;   // turned: the stops' boxes are measured anew
      last = p;
    } else if (mode === 'pan') {
      cam.stop = null;
      cam.panX += p.x - last.x;
      cam.panY += p.y - last.y;
      applyView(fit, cam);
      last = p;
    }
  });
  const end = ev => {
    pointers.delete(ev.pointerId);
    if (pointers.size) return;
    if (mode === 'turn') {
      for (const b of document.querySelectorAll('#presets button')) b.classList.remove('active');
    }
    mode = null;
    stage.classList.remove('dragging');
  };
  stage.addEventListener('pointerup', end);
  stage.addEventListener('pointercancel', end);
  stage.addEventListener('wheel', ev => {
    if (!ev.ctrlKey) return;   // a plain wheel scrolls the page
    ev.preventDefault();
    const p = at(ev);
    zoomAt(fit, cam, Math.exp(-ev.deltaY * 0.01), p.x, p.y);
  }, {passive: false});
  let gestureZoom = 1;   // Safari's trackpad pinch
  stage.addEventListener('gesturestart', ev => { ev.preventDefault(); gestureZoom = 1; });
  stage.addEventListener('gesturechange', ev => {
    ev.preventDefault();
    const p = at(ev);
    zoomAt(fit, cam, ev.scale / gestureZoom, p.x, p.y);
    gestureZoom = ev.scale;
  });
}

// Free 3D's canvas is as tall as you drag its bottom edge, kept for every config (until
// then 68% of the window's height). The scene keeps its size and stays centred.
const FREE_HEIGHT = 'screenmaps.freeHeight';
function freeHeight() {
  try { return Number(localStorage.getItem(FREE_HEIGHT)) || 0; } catch (e) { return 0; }
}

function initFreeResize(stage, fit, cam) {
  const edge = el('div', 'free-resize');
  edge.title = 'Drag to set the canvas’s height';
  stage.append(edge);
  let start = null;
  edge.addEventListener('pointerdown', ev => {
    ev.stopPropagation();   // not a turn or a pan
    ev.preventDefault();
    hidePop();
    try { edge.setPointerCapture(ev.pointerId); } catch (e) { /* a synthetic pointer */ }
    start = {y: ev.clientY, h: stage.offsetHeight};
    stage.classList.add('resizing');
  });
  edge.addEventListener('pointermove', ev => {
    if (!start) return;
    const h = Math.round(Math.max(240, Math.min(4000, start.h + ev.clientY - start.y)));
    cam.panY += (h - stage.offsetHeight) / 2;
    stage.style.height = `${h}px`;
    applyView(fit, cam);
  });
  const end = () => {
    if (!start) return;
    start = null;
    stage.classList.remove('resizing');
    try { localStorage.setItem(FREE_HEIGHT, String(stage.offsetHeight)); } catch (e) { /* lasts the visit */ }
  };
  edge.addEventListener('pointerup', end);
  edge.addEventListener('pointercancel', end);
}

// Free 3D's Tab: fly to the next stop (⇧Tab the one before), all the displays then each
// display, zooming and panning just enough to fit it, without turning the scene. The
// stops' boxes are measured at your zoom 1 and no pan, once per angle, so a Tab pressed
// mid-flight aims right.
function flyTo(step) {
  const fly = state.fly;
  if (!fly) return;
  const {stage, fit, cam, stops} = fly;
  if (!fly.boxes) {
    const sr = stage.getBoundingClientRect();
    fly.boxes = stops.map(stop => {
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const n of stop.nodes()) {
        const r = n.getBoundingClientRect();
        x0 = Math.min(x0, r.left - sr.left);
        y0 = Math.min(y0, r.top - sr.top);
        x1 = Math.max(x1, r.right - sr.left);
        y1 = Math.max(y1, r.bottom - sr.top);
      }
      // back to zoom 1, no pan: the screen box is pan + zoom × that
      return {x0: (x0 - cam.panX) / cam.zoom, y0: (y0 - cam.panY) / cam.zoom,
              x1: (x1 - cam.panX) / cam.zoom, y1: (y1 - cam.panY) / cam.zoom};
    });
  }
  const n = stops.length;
  cam.stop = ((cam.stop == null ? (step > 0 ? -1 : 0) : cam.stop) + step + n) % n;
  const b = fly.boxes[cam.stop];
  const W = stage.clientWidth, H = stage.clientHeight;
  const z = Math.min(8, Math.min(W / (b.x1 - b.x0), H / (b.y1 - b.y0)) * 0.9);
  cam.zoom = z;
  cam.panX = W / 2 - z * (b.x0 + b.x1) / 2;
  cam.panY = H / 2 - z * (b.y0 + b.y1) / 2;
  fit.style.transition = 'transform 0.6s cubic-bezier(0.4, 0, 0.2, 1)';
  applyView(fit, cam);
  clearTimeout(fly.landing);
  fly.landing = setTimeout(() => landFlight(fit), 650);
  showStop(cam.stop);
}

function landFlight(fit) {
  fit.style.transition = '';
}

function showStop(i) {
  const where = state.fly && state.fly.stage.querySelector('.free-where');
  if (where && state.fly.stops[i]) where.textContent = `→ ${state.fly.stops[i].label}`;
}

// --- Days: by the day each window was opened, and by the day it was last used --------

function renderDays(map, live) {
  const box = $('days');
  box.textContent = '';
  if (map.rebuilt) {
    box.append(el('p', 'empty', 'This layout is rebuilt from a save from before screenmaps, which kept no times.'));
    return;
  }
  const items = [
    ...map.windows.map((w, z) => ({w, z})),
    ...map.minimized.map(w => ({w, z: null})),
  ];
  const cols = el('div', 'days-cols');
  cols.append(
    daysColumn(map, items, 'Opened', 'seen', 'First saved; the ones open before screenmaps began say so'),
    daysColumn(map, items, 'Last used', 'used', 'Brought to the front, moved or minimized'),
  );
  box.append(cols);
}

function daysColumn(map, items, title, field, hint) {
  const col = el('div', 'days-col');
  const head = el('div', 'days-head');
  head.append(el('h3', null, title), el('span', 'panel-hint', hint));
  col.append(head);
  const groups = new Map();
  for (const it of items) {
    const ts = it.w[field];
    if (!ts) continue;
    let key, label, sort;
    if (field === 'seen' && map.since && ts <= map.since) {
      // When these opened is unknown: before screenmaps' first save of this config
      key = 'before';
      label = `${dayLabel(map.since)}, already open`;
      sort = dayStart(map.since) - 1;
    } else {
      sort = dayStart(ts);
      key = String(sort);
      label = dayLabel(ts);
    }
    if (!groups.has(key)) groups.set(key, {label, sort, items: []});
    groups.get(key).items.push(it);
  }
  const rows = el('div', 'map-days');
  for (const g of [...groups.values()].sort((a, b) => b.sort - a.sort)) {
    const row = el('div', 'map-day');
    const dayFilter = `${title} ${g.label}`;
    const dayBtn = el('button', 'map-day-label', g.label + ' ');
    dayBtn.type = 'button';
    dayBtn.dataset.filter = dayFilter;
    dayBtn.append(el('span', 'count', String(g.items.length)));
    dayBtn.onclick = () => setFilter(dayFilter, g.items.map(it => keyOf(it.w)));
    row.append(dayBtn);
    // Each app once, with how many of its windows, most first
    const byApp = new Map();
    for (const it of g.items) {
      if (!byApp.has(it.w.app)) byApp.set(it.w.app, []);
      byApp.get(it.w.app).push(it);
    }
    const chips = el('div', 'map-chips');
    for (const [app, its] of [...byApp.entries()].sort((a, b) => b[1].length - a[1].length)) {
      const chipFilter = `${dayFilter}: ${app}`;
      const chip = el('button', 'map-chip');
      chip.type = 'button';
      chip.dataset.filter = chipFilter;
      if (its.length > 1) chip.append(el('span', null, String(its.length)));
      chip.append(iconEl(its[0].w));
      chip.onclick = () => setFilter(chipFilter, its.map(it => keyOf(it.w)));
      onHover(chip, () => {
        const h = el('div', 'pop-title');
        h.append(iconEl(its[0].w), el('span', null, `${app} · ${its.length} window${its.length === 1 ? '' : 's'}`));
        const ul = el('ul', 'pop-list');
        for (const it of its.slice(0, 8)) {
          ul.append(el('li', null, `${cleanTitle(it.w)}${it.z == null ? ' (minimized)' : ''} · ${when(it.w[field])}`));
        }
        if (its.length > 8) ul.append(el('li', null, `and ${its.length - 8} more`));
        return [h, ul];
      });
      chips.append(chip);
    }
    row.append(chips);
    rows.append(row);
  }
  col.append(rows);
  return col;
}

// --- List: a bulleted list per display, laid out as the displays stand --------------

function displaySection(map, d, wins, live) {
  const sec = el('section', 'screen-list');
  sec.dataset.screen = screenId(d);
  const h = el('h3', null, displayName(d) + ' ');
  h.append(el('span', 'count', String(wins.length)));
  sec.append(h, el('div', 'monitor', monitorText(d)));
  const ul = el('ul');
  for (const {w, z} of wins) {
    const li = el('li', z === 0 ? 'focused' : null);
    tagWindow(li, w, d);
    li.append(iconEl(w), titleEl(w, live), ' ', appToggle(map, w));
    onHover(li, () => windowPop(map, w, z, live));
    ul.append(li);
  }
  if (!wins.length) ul.append(el('li', 'none', 'no windows'));
  sec.append(ul);
  return sec;
}

function renderList(map, live) {
  const box = $('list');
  box.textContent = '';
  const by = windowsByDisplay(map);
  const cols = displayColumns(map.displays);
  const grid = el('div', 'list-cols');
  grid.style.setProperty('--cols', String(cols.length));
  for (const col of cols) {
    const c = el('div', 'list-col');
    for (const d of col) c.append(displaySection(map, d, by.get(d), live));
    grid.append(c);
  }
  box.append(grid);
  if (map.minimized.length) {
    const sec = el('section', 'screen-list minimized-list');
    const h = el('h3', null, 'Minimized ');
    h.append(el('span', 'count', String(map.minimized.length)));
    const ul = el('ul');
    for (const w of map.minimized) {
      const li = el('li');
      tagWindow(li, w);
      const d = displayOf(map, w);
      li.append(iconEl(w), titleEl(w, live), ' ', appToggle(map, w), d ? el('span', 'from', `, from ${displayName(d)}`) : '');
      onHover(li, () => windowPop(map, w, null, live));
      ul.append(li);
    }
    sec.append(h, ul);
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
    const ext = c.screens - 1;
    b.title = ext ? `the built-in and ${ext} external display${ext > 1 ? 's' : ''}` : 'the built-in display alone';
    if (current) b.title += ', in use now';
    b.append(el('span', 'when', shortWhen(entry.map.saved)));
    b.onclick = () => { state.chosen = c.name; state.filter = null; render(); };
    nav.append(b);
  }
}

function render() {
  hidePop();
  hovered = null;   // the new nodes aren't lit yet: the next mouseover lights them
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
  const nd = map.displays.length, nw = map.windows.length, nm = map.minimized.length;
  $('summary').textContent = `${nw} window${nw === 1 ? '' : 's'} on ${nd} display${nd === 1 ? '' : 's'}` +
    (nm ? `, ${nm} minimized` : '');
  if (map.rebuilt) {
    $('summary').append(' · ', el('span', 'note',
      'rebuilt from its layout save, from before screenmaps: displays without windows are missing'));
  }
  $('panel').classList.toggle('show-days', state.view === 'days');
  for (const b of document.querySelectorAll('.panel-views button')) {
    b.classList.toggle('active', b.dataset.view === state.view);
  }
  for (const id of ['presets', 'stack', 'mapHint']) $(id).hidden = state.view !== 'map';
  renderMapControls(name);
  renderAppFilters(map);
  if (state.view === 'map') renderMap(map, live, name);
  else renderDays(map, live);
  renderList(map, live);
  applyFilter();
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
  const chrome = await fetchChrome();
  const chromeSig = chrome ? String(chrome.taken) : '';
  if (sig === state.nowSig && chromeSig === state.chromeSig) return;
  const mapsChanged = sig !== state.nowSig;
  state.nowSig = sig;
  state.now = now;
  state.chrome = chrome;
  state.chromeSig = chromeSig;
  if (mapsChanged) await loadMaps();
  // mid-drag in free 3D, wait for the next poll
  if (document.querySelector('.map-stage.dragging, .map-stage.resizing')) { state.chromeSig = ''; state.nowSig = ''; return; }
  render();
}

for (const b of document.querySelectorAll('.panel-views button')) {
  b.addEventListener('click', () => setView(b.dataset.view));
}
initHoverLinks();
initFocusClicks();
for (const b of document.querySelectorAll('#presets button')) {
  b.addEventListener('click', () => setPreset(b.dataset.preset));
}
for (const b of document.querySelectorAll('#stack button')) {
  b.addEventListener('click', () => setStack(b.dataset.stack));
}
document.addEventListener('keydown', ev => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  const keyed = {1: 'flat', 2: 'turned', 3: 'ground'}[ev.key];
  if (keyed && state.now && state.view === 'map') {
    setPreset(keyed);
  } else if (ev.key === 's' && state.now && state.view === 'map') {
    setStack(stackOf() === 'below' ? 'above' : 'below');
  } else if (ev.key === 'Tab' && state.fly && state.view === 'map') {
    ev.preventDefault();
    flyTo(ev.shiftKey ? -1 : 1);
  }
  if (ev.key === 'm') setView('map');
  else if (ev.key === 'd') setView('days');
  else if (ev.key === 'Escape') {
    hidePop();
    if (state.filter) { state.filter = null; applyFilter(); }
  }
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
