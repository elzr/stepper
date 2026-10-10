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
// A click brings the window forward through Hammerspoon, so only on the Mac itself
// (an iPad reports MacIntel too, but with touch points)
const ON_MAC = /Mac/.test(navigator.platform) && navigator.maxTouchPoints === 0;

const $ = id => document.getElementById(id);
const state = {
  now: null,        // screenmaps-now.json
  nowSig: '',
  maps: {},         // config name → {sig, map}
  appBundles: {},   // app name → bundle ID, from the running apps and every map
  chosen: null,     // the config picked by hand during this visit
  view: localStorage.getItem('screenmaps.view') === 'days' ? 'days' : 'map',
  filter: null,     // {label, keys}: the windows a day or app in Days picked out
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
    name: doc.config, saved: doc.saved, since: doc.since, rebuilt: false,
    displays: list(doc.displays),
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

// A window's title as a link that brings it forward (the config in use, on the Mac), or text
function titleEl(w, live, cls) {
  const clickable = live && w.id != null && ON_MAC;
  const t = el(clickable ? 'a' : 'span', cls, cleanTitle(w));
  if (clickable) t.href = `hammerspoon://screenmaps?focus=${w.id}`;
  return t;
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
function windowPop(map, w, z, live) {
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
  if (live && w.id != null && ON_MAC) {
    nodes.push(el('div', 'pop-line act', z == null ? 'Click to bring it back from the Dock' : 'Click to bring it forward'));
  }
  return nodes;
}

// --- Filter: the windows a day or an app in Days picked out, the rest dimmed ---------

function setFilter(label, keys) {
  state.filter = state.filter && state.filter.label === label ? null : {label, keys: new Set(keys)};
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
    node.classList.toggle('hit', hit);
  }
  for (const node of document.querySelectorAll('[data-filter]')) {
    node.classList.toggle('active', !!f && node.dataset.filter === f.label);
  }
}

// --- Map --------------------------------------------------------------------------

function renderMap(map, live) {
  const box = $('map');
  box.textContent = '';
  const ds = map.displays;
  if (!ds.length) {
    box.append(el('p', 'empty', 'No displays saved for this config.'));
    return;
  }
  const rects = physicalRects(ds);
  const rs = [...rects.values()];
  const minX = Math.min(...rs.map(r => r.x)), minY = Math.min(...rs.map(r => r.y));
  const maxX = Math.max(...rs.map(r => r.x + r.w)), maxY = Math.max(...rs.map(r => r.y + r.h));
  const width = box.clientWidth || 1000;
  const scale = Math.min(width / (maxX - minX), Math.max(320, window.innerHeight * 0.68) / (maxY - minY));
  const left = (width - (maxX - minX) * scale) / 2;   // centred when the height limits it
  const stage = el('div', 'map-stage');
  stage.style.height = `${Math.ceil((maxY - minY) * scale)}px`;
  box.append(stage);

  const by = windowsByDisplay(map);
  const total = map.windows.length;
  for (const d of ds) {
    const r = rects.get(d);
    const sx = (r.w / d.full.w) * scale, sy = (r.h / d.full.h) * scale;   // px per point here
    const de = el('div', 'display' + (isBuiltin(d) ? ' builtin' : ''));
    de.style.left = `${left + (r.x - minX) * scale + GAP / 2}px`;
    de.style.top = `${(r.y - minY) * scale + GAP / 2}px`;
    de.style.width = `${r.w * scale - GAP}px`;
    de.style.height = `${r.h * scale - GAP}px`;
    const bar = d.frame.y - d.full.y;   // the menu bar
    if (bar > 0) {
      const mb = el('div', 'menubar');
      mb.style.height = `${bar * sy}px`;
      de.append(mb);
    }
    const wins = by.get(d);
    wins.forEach(({w, z}, i) => {
      const clickable = live && w.id != null && ON_MAC;
      const we = el(clickable ? 'a' : 'div', 'win');
      if (clickable) we.href = `hammerspoon://screenmaps?focus=${w.id}`;
      we.dataset.key = keyOf(w);
      if (z === 0) we.classList.add('focused');
      if (i === 0) we.classList.add('front');
      // Inside its display, which clips it the way macOS does
      const ww = w.frame.w * sx, wh = w.frame.h * sy;
      we.style.left = `${(w.frame.x - d.full.x) * sx - GAP / 2}px`;
      we.style.top = `${(w.frame.y - d.full.y) * sy - GAP / 2}px`;
      we.style.width = `${ww}px`;
      we.style.height = `${wh}px`;
      we.style.zIndex = String(total - z);
      we.style.setProperty('--hue', hue(bundleOf(w) || w.app));
      if (ww < 48 || wh < 22) we.classList.add('tiny');
      const head = el('div', 'win-head');
      head.append(iconEl(w), el('span', 'win-title', cleanTitle(w)));
      we.append(head);
      // Big enough: its app's icon, faded, in the middle, to tell the apps apart at a glance
      if (ww >= 70 && wh >= 64) we.append(iconEl(w, 'win-mark'));
      onHover(we, () => windowPop(map, w, z, live));
      de.append(we);
    });
    const label = el('div', 'display-label', displayName(d));
    if (d.mm) label.append(el('span', 'size', ` ${inches(d)}`));
    label.append(el('span', 'count', ` · ${wins.length}`));
    de.title = monitorText(d);
    de.append(label);
    stage.append(de);
  }

  // The minimized windows after a rule, as the tablogs show minimized Chrome windows
  if (map.minimized.length) {
    box.append(el('div', 'map-divider', `Minimized windows · ${map.minimized.length}`));
    const strip = el('div', 'min-strip');
    for (const w of map.minimized) {
      const clickable = live && w.id != null && ON_MAC;
      const chip = el(clickable ? 'a' : 'div', 'min-chip');
      if (clickable) chip.href = `hammerspoon://screenmaps?focus=${w.id}`;
      chip.dataset.key = keyOf(w);
      chip.style.setProperty('--hue', hue(bundleOf(w) || w.app));
      chip.append(iconEl(w), el('span', 'min-title', cleanTitle(w)));
      onHover(chip, () => windowPop(map, w, null, live));
      strip.append(chip);
    }
    box.append(strip);
  }
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
  const h = el('h3', null, displayName(d) + ' ');
  h.append(el('span', 'count', String(wins.length)));
  sec.append(h, el('div', 'monitor', monitorText(d)));
  const ul = el('ul');
  for (const {w, z} of wins) {
    const li = el('li', z === 0 ? 'focused' : null);
    li.dataset.key = keyOf(w);
    li.append(iconEl(w), titleEl(w, live), ' ', el('span', 'app', w.app));
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
      li.dataset.key = keyOf(w);
      const d = displayOf(map, w);
      li.append(iconEl(w), titleEl(w, live), ' ', el('span', 'app', `${w.app}${d ? ', from ' + displayName(d) : ''}`));
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
  const action = live && ON_MAC ? '; click one to bring it forward' : '';
  $('hint').textContent = state.view === 'map'
    ? `Each display at its real size, where it sits, each window where it was; hover one for its title${action}`
    : 'Click a day or an app to pick out its windows in the list below';
  if (state.view === 'map') renderMap(map, live);
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
