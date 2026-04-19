// keymap.js — click-to-filter keys and pill-toggle layers
//
// Filters compose as AND: a key filter narrows by data-key,
// a layer pill narrows by data-layer.
// Click the same key again (or the pill ✕) to clear the key filter.

(function () {
  'use strict';

  let activeKey = null;
  let activeLayer = 'all';

  const tableRows = document.querySelectorAll('table.bindings tbody tr');
  const allKeyTiles = document.querySelectorAll('.kb .key');
  const layerButtons = document.querySelectorAll('.filters button[data-filter]');
  const keyPill = document.querySelector('.key-pill');
  const keyPillLabel = document.getElementById('key-filter');
  const clearKeyBtn = document.querySelector('.key-pill .clear-key');

  function applyFilters() {
    tableRows.forEach(function (row) {
      const k = row.getAttribute('data-key');
      const l = row.getAttribute('data-layer');
      const matchesKey = !activeKey || k === activeKey;
      const matchesLayer = activeLayer === 'all' || l === activeLayer;
      row.classList.toggle('hidden', !(matchesKey && matchesLayer));
    });

    // Visual emphasis on the keyboard for active key/layer
    allKeyTiles.forEach(function (tile) {
      const k = tile.getAttribute('data-key');
      tile.classList.toggle('highlight', activeKey && k === activeKey);
      // Dim any tile that doesn't match the layer filter
      let dim = false;
      if (activeKey && k !== activeKey) dim = true;
      if (activeLayer !== 'all') {
        const layerClass = 'has-' + activeLayer;
        if (!tile.classList.contains(layerClass)) dim = true;
      }
      tile.classList.toggle('dim', dim);
    });
  }

  function setKeyFilter(k) {
    activeKey = k;
    if (keyPill) {
      if (k) {
        keyPill.removeAttribute('hidden');
        if (keyPillLabel) keyPillLabel.textContent = k;
      } else {
        keyPill.setAttribute('hidden', '');
      }
    }
    applyFilters();
  }

  function setLayerFilter(l) {
    activeLayer = l;
    layerButtons.forEach(function (b) {
      b.classList.toggle('active', b.getAttribute('data-filter') === l);
    });
    applyFilters();
  }

  // Wire up clicks on every key tile (incl. arrow halves & arrow-stack children)
  allKeyTiles.forEach(function (tile) {
    tile.addEventListener('click', function () {
      const k = tile.getAttribute('data-key');
      if (!k) return;
      setKeyFilter(activeKey === k ? null : k);
    });
  });

  // Wire up layer pills
  layerButtons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      setLayerFilter(btn.getAttribute('data-filter'));
    });
  });

  // Wire up clear-key button
  if (clearKeyBtn) {
    clearKeyBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      setKeyFilter(null);
    });
  }
})();
