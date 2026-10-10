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

const TAG_ROOM = 240;   // 3D: px left of the stacks for the column of window names

// The map's displays and windows sit on a plane. Flat, it's the stage; in 3D it's tilted
// to an isometric angle, each window one layer above the one behind it on its display
// (the stack the saves record front to back), with the windows' names in a column beside.
function renderMap(map, live, depth) {
  const box = $('map');
  box.textContent = '';
  const ds = map.displays;
  if (!ds.length) {
    box.append(el('p', 'empty', 'No displays saved for this config.'));
    return;
  }
  const threeD = depth === '3d';
  const rects = physicalRects(ds);
  const rs = [...rects.values()];
  const minX = Math.min(...rs.map(r => r.x)), minY = Math.min(...rs.map(r => r.y));
  const maxX = Math.max(...rs.map(r => r.x + r.w)), maxY = Math.max(...rs.map(r => r.y + r.h));
  const width = box.clientWidth || 1000;
  const room = Math.max(320, window.innerHeight * 0.68);
  // Flat: the arrangement fills the width, or the room. 3D: a plane small enough that,
  // tilted and stacked, it fits beside the names at full size
  const scale = threeD
    ? ((width - TAG_ROOM) * 0.7) / (maxX - minX)
    : Math.min(width / (maxX - minX), room / (maxY - minY));
  const left = threeD ? 0 : (width - (maxX - minX) * scale) / 2;   // flat: centred
  const planeHeight = Math.ceil((maxY - minY) * scale);
  const stage = el('div', 'map-stage' + (threeD ? ' three-d' : ''));
  const fit = el('div', 'fit');
  const plane = el('div', 'plane');
  plane.style.width = `${threeD ? Math.ceil((maxX - minX) * scale) : width}px`;
  plane.style.height = `${planeHeight}px`;
  fit.append(plane);
  stage.append(fit);
  stage.style.height = `${planeHeight}px`;
  box.append(stage);

  const by = windowsByDisplay(map);
  const total = map.windows.length;
  // 3D layers: far enough apart for a name between two, closer in a tall stack
  const tallest = Math.max(1, ...[...by.values()].map(wins => wins.length));
  const layer = Math.max(10, Math.min(20, 480 / tallest));
  const corners = [];   // 3D: each window's corner that its name points at
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
      // Big enough: its app's icon, faded, in the middle, to tell the apps apart at a glance
      if (ww >= 70 && wh >= 64) we.append(iconEl(w, 'win-mark'));
      onHover(we, () => windowPop(map, w, z, live));
      de.append(we);
      if (threeD) {
        // The display's front window on top: i is its place in this display's stack
        const lift = `translateZ(${(wins.length - i) * layer}px)`;
        we.style.transform = lift;
        // Its top-left corner: the plane's tilt makes it the layer's leftmost point,
        // the nearest to the names
        const corner = el('i', 'corner');
        corner.style.left = `${wl}px`;
        corner.style.top = `${wt}px`;
        corner.style.transform = lift;
        de.append(corner);
        corners.push({corner, w, z, clickable, d, rank: i});
      }
    });
    const label = el('div', 'display-label', displayName(d));
    if (d.mm) label.append(el('span', 'size', ` ${inches(d)}`));
    label.append(el('span', 'count', ` · ${wins.length}`));
    de.title = monitorText(d);
    de.append(label);
    plane.append(de);
  }
  if (threeD) {
    fitInStage(stage, fit, width - TAG_ROOM, TAG_ROOM);
    placeNames(map, stage, corners, live);
    centreComposition(stage, fit);
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

// The tilted plane's projection spills out of its box: measure what its displays and windows
// cover on screen, then move it beside the names' column (and shrink it if it's too wide;
// a tall stack just makes the stage taller, so the names keep their size)
function fitInStage(stage, fit, maxWidth, leftPad) {
  const sr = stage.getBoundingClientRect();
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const n of stage.querySelectorAll('.display, .win')) {
    const r = n.getBoundingClientRect();
    x0 = Math.min(x0, r.left);
    y0 = Math.min(y0, r.top);
    x1 = Math.max(x1, r.right);
    y1 = Math.max(y1, r.bottom);
  }
  const w = x1 - x0, h = y1 - y0;
  if (!(w > 0 && h > 0)) return;
  const s = Math.min(1, maxWidth / w), pad = 12;
  fit.style.transform = `translate(${leftPad + (maxWidth - w * s) / 2 - (x0 - sr.left) * s}px, ` +
    `${pad - (y0 - sr.top) * s}px) scale(${s})`;
  stage.style.height = `${Math.ceil(h * s) + 2 * pad}px`;
}

// 3D: centre the names and the stacks together in the stage
function centreComposition(stage, fit) {
  const sr = stage.getBoundingClientRect();
  let x0 = Infinity, x1 = -Infinity;
  for (const n of stage.querySelectorAll('.display, .win, .layer-name')) {
    const r = n.getBoundingClientRect();
    x0 = Math.min(x0, r.left);
    x1 = Math.max(x1, r.right);
  }
  const dx = (sr.width - (x1 - x0)) / 2 - (x0 - sr.left);
  if (!Number.isFinite(dx)) return;
  fit.style.transform = `translateX(${dx}px) ${fit.style.transform}`;
  stage.querySelector('.names').style.transform = `translateX(${dx}px)`;
}

// 3D: the windows' names upright in a column left of the stacks, read as the stacks are:
// display by display (as the list lays them out), each front to back, with a hairline from
// each name to its window's top-left corner. With several displays the lines would cross
// the whole map, so the column gets a heading per display and a name's line shows while
// it's hovered. The names take the windows' hover, click and Days picks.
function placeNames(map, stage, corners, live) {
  const sr = stage.getBoundingClientRect();
  const layerEl = el('div', 'names');
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('name-lines');
  layerEl.append(svg);
  stage.append(layerEl);
  const order = displayColumns(map.displays).flat();
  const points = corners.map(c => {
    const r = c.corner.getBoundingClientRect();
    return {...c, x: r.left - sr.left, y: r.top - sr.top};
  }).sort((p, q) => order.indexOf(p.d) - order.indexOf(q.d) || p.rank - q.rank);
  const LINE = 18, GROUP_GAP = 10;
  const groups = new Set(points.map(p => p.d)).size;
  const several = groups > 1;
  const columnHeight = (points.length + (several ? groups : 0)) * LINE + (groups - 1) * GROUP_GAP;
  const ys = points.map(p => p.y);
  // Centred on the corners it points at
  let next = Math.max(4, (Math.min(...ys) + Math.max(...ys)) / 2 - columnHeight / 2);
  const columnRight = Math.min(...points.map(p => p.x)) - 16;
  const svgEl = tag => document.createElementNS('http://www.w3.org/2000/svg', tag);
  points.forEach((p, k) => {
    const firstOfDisplay = k === 0 || p.d !== points[k - 1].d;
    if (k > 0 && firstOfDisplay) next += GROUP_GAP;
    if (several && firstOfDisplay) {
      const heading = el('div', 'name-group', displayName(p.d) + (p.d.mm ? ` ${inches(p.d)}` : ''));
      heading.style.top = `${next}px`;
      heading.style.right = `${sr.width - columnRight}px`;
      layerEl.append(heading);
      next += LINE;
    }
    const top = next;
    next += LINE;
    const name = el(p.clickable ? 'a' : 'div', 'layer-name' + (p.z === 0 ? ' focused' : ''));
    if (p.clickable) name.href = `hammerspoon://screenmaps?focus=${p.w.id}`;
    name.dataset.key = keyOf(p.w);
    name.style.top = `${top}px`;
    name.style.right = `${sr.width - columnRight}px`;
    name.append(iconEl(p.w), el('span', null, cleanTitle(p.w)));
    onHover(name, () => windowPop(map, p.w, p.z, live));
    layerEl.append(name);
    const line = svgEl('line');
    line.setAttribute('x1', columnRight + 4);
    line.setAttribute('y1', top + LINE / 2);
    line.setAttribute('x2', p.x);
    line.setAttribute('y2', p.y);
    const dot = svgEl('circle');
    dot.setAttribute('cx', p.x);
    dot.setAttribute('cy', p.y);
    dot.setAttribute('r', 2);
    if (several) {
      line.classList.add('on-hover');
      dot.classList.add('on-hover');
      name.addEventListener('mouseenter', () => { line.classList.add('shown'); dot.classList.add('shown'); });
      name.addEventListener('mouseleave', () => { line.classList.remove('shown'); dot.classList.remove('shown'); });
    }
    svg.append(line, dot);
  });
  if (next + 12 > sr.height) stage.style.height = `${Math.ceil(next + 12)}px`;
}

// Flat or 3D, per config. 3D by default for the laptop alone, whose mostly maximized
// windows hide each other on a flat map
function depthOf(name) {
  const picked = localStorage.getItem(`screenmaps.depth.${name}`);
  if (picked === 'flat' || picked === '3d') return picked;
  const c = list(state.now.configs).find(c => c.name === name);
  return c && c.screens === 1 ? '3d' : 'flat';
}

function setDepth(depth) {
  const name = state.now && shownConfig();
  if (!name) return;
  localStorage.setItem(`screenmaps.depth.${name}`, depth);
  render();
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
  const depth = depthOf(name);
  $('depth').hidden = state.view !== 'map';
  for (const b of document.querySelectorAll('#depth button')) {
    b.classList.toggle('active', b.dataset.depth === depth);
  }
  const action = live && ON_MAC ? '; click one to bring it forward' : '';
  $('hint').textContent = state.view === 'days'
    ? 'Click a day or an app to pick out its windows in the list below'
    : depth === '3d'
      ? `Each window a layer above the one behind it, the front one on top; hover a window or its name for its title${action}`
      : `Each display at its real size, where it sits, each window where it was; hover one for its title${action}`;
  if (state.view === 'map') renderMap(map, live, depth);
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
for (const b of document.querySelectorAll('#depth button')) {
  b.addEventListener('click', () => setDepth(b.dataset.depth));
}
document.addEventListener('keydown', ev => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  if (ev.key === '3' && state.now && state.view === 'map') {
    setDepth(depthOf(shownConfig()) === '3d' ? 'flat' : '3d');
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
