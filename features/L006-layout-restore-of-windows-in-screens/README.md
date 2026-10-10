# L006 — Layout Restore of Windows in Screens

> Automatic save and restore of window positions across a 5-display desk setup, handling the many ways macOS scrambles windows after sleep, screen lock, and display reconnection.

## The problem

The user's desk has a MacBook Pro + 4 identical LG HDR 4K monitors (via two USB-C hubs). None of these LG displays expose unique EDID serial numbers — macOS sees them as four copies of "LG HDR 4K." macOS had been using Thunderbolt port enumeration order to tell them apart, which worked by accident — until it didn't. After sleep, screen lock, or cable replug, macOS routinely shuffles windows to the wrong displays.

This feature provides a complete save/restore system that:
- Identifies screens by **spatial position** (not serial, not port)
- **Auto-saves** every minute while all 5 displays are connected
- **Auto-restores** when displays return, when the system wakes, or when the screen unlocks
- **Protects** the save file from being overwritten with macOS's wrong positions

## How it works

### Display configs

==🟢Each known config has its own layout file, manual save and backup rings==, and autosaves only into its own file, so a partial setup can't overwrite the desk's. They are [layout.lua](../../lua/layout.lua)'s `KNOWN_CONFIGS`, keyed by screen count and ==🔵named by their external displays since 2026-10-09== ([changelog](../../changelog/2026-10-09-configs-named-by-their-externals.md); quad was quad-32):

| Config | Screens | Displays |
|------|---------|----------|
| **quad** | 5 | the built-in, two 32″ LG HDR 4K (top and center), two 37″ Samsung LS37D70xE in portrait (left and right); Lunar sync and the [arrangement guard](../F010-sync-display-names-in-Lunar/README.md#arrangement-guard) |
| **dual** | 3 | the built-in and two externals |
| **single** | 2 | the built-in and one external |
| **native** | 1 | the built-in alone; `gather()` consolidates windows onto it |

A count with no config (4, while a dock ramps up) is transitional: nothing saves until a known count holds.

### Screen identification

Since monitors can be identical to macOS (the two Samsungs share an EDID serial, as the four LGs once did), screens are identified by spatial position relative to the built-in MacBook display (the anchor):

```
         ┌─────────┐
         │   top    │
         └─────────┘
┌──────┐ ┌─────────┐ ┌──────┐
│ left │ │  center  │ │right │
└──────┘ └─────────┘ └──────┘
         ┌─────────┐
         │ bottom  │
         │(built-in│
         └─────────┘
```

Classification (via [screenswitch.lua](../../lua/screenswitch.lua) `buildScreenMap()`):
- Screens whose center X falls within the built-in's X range → **center column**, sorted by Y → `center`, `top`
- Others → **sides**, sorted by X → `left`, `right`
- Built-in display → always `bottom`

This spatial approach is stable across reconnections because macOS preserves the display arrangement in System Settings even when UUIDs shuffle.

### Save pipeline

Every save ([layout.lua](../../lua/layout.lua) `M.save()`) captures:

| Field | Purpose |
|-------|---------|
| `app`, `title` | Window identity for matching on restore |
| `screenPosition` | Position name ("center", "left", etc.) — primary screen identifier |
| `screenFrame` | Absolute screen coordinates — fallback for old saves |
| `frame` | Absolute window coordinates |
| `frameRel` | Relative position (fractions of screen) — for cross-resolution restore |

**Filters:** Ghost windows (tooltips, popovers, find bars) are excluded via `isGhostWindow()` — see [ghost windows deep dive](2026-03-22-fix-ghost-windows.md).

**Off the main thread:** ==🟢[layoutsnap.swift](../../lua/layoutsnap.swift) reads the windows in its own process==, apps in parallel, each Accessibility call capped at 1 s, so a busy app can't stall stepper's hotkeys. Hammerspoon's main thread only files the result (6–12 ms). An app that doesn't answer keeps its last saved windows (`save-kept`). A save that would write what the file already says writes nothing. The save before sleep reads in Hammerspoon instead, so it finishes before the system sleeps. `layout.saveStats()` shows how saves went since load. See [the changelog](../../changelog/2026-10-09-layout-saves-off-the-main-thread.md).

**Position protection during save:** After a reconnection, if a window is still on the wrong screen (macOS hasn't been corrected yet), the save substitutes the ground-truth position from the protected entries instead of recording the wrong position.

### Restore pipeline

Restore (`M.restoreFromJSON()`) has two phases:

**Phase 1 — Window matching** (3 tiers, scoped per app):
1. **Exact title** — `win:title() == entry.title`
2. **40-char prefix** — handles title suffixes that change (e.g., "- Edited")
3. **Index fallback** — first unmatched window for the same app (with 100x100 size guard)

**Phase 2 — Screen matching** (4 passes):
1. **Position name** — finds the screen currently at `screenPosition` via `buildScreenMap()`
2. **Origin match** — screen at same (x, y) within 2px tolerance
3. **Resolution match** — same width/height within 2px
4. **Fallback** — main screen

After matching, windows are moved instantly (`animationDuration = 0`), then z-order is replayed back-to-front via `focus()`.

### Three restore triggers

macOS can scramble windows in three different scenarios, each detected differently:

| Scenario | What happens | Detection | Response |
|----------|-------------|-----------|----------|
| **Display reconnection** | Screens disconnect then reconnect (unplug, reboot, hub reset) | Screen watcher: count transitions to 5 (2s debounce + 1s delay) | Full restore + retry + position protection |
| **System sleep** | `screensDidWake` fires | Caffeinate watcher in [stepper.lua](../../lua/stepper.lua) | `onWake()`: 3s settle → drift check → conditional restore |
| **Screen lock / display sleep** | `screensDidWake` does **not** fire; `orderedWindows()` returns 0 during lock | Zero-window streak in `autoSave()` (0 → N transition) | Treated as wake: calls `onWake()` |

The screen lock scenario was the last gap closed (2026-03-23). See [the chronicle](chronicle.md) for the full story.

### Retry mechanism

Some windows (especially Chrome) aren't visible to `orderedWindows()` immediately after reconnection. The retry loop:
- Polls every 3s for up to 30s (10 attempts)
- Uses only Tier 1 and Tier 2 matching (no index fallback — too risky during retry)
- Suppresses autosave during retry to prevent saving partial restores
- On success: triggers a "heal save" to record the corrected layout

### Position protection

After reconnection or wake-with-drift, all saved entries become "ground truth" for 5 minutes. During this window, if autosave runs and a window is on a different screen than saved, the save file gets the ground-truth position instead of the wrong one. This prevents the most insidious failure: autosave permanently overwriting the correct layout with macOS's mistakes.

### Backup rings

Two rotating backup rings in [data/layout-backups/](../../data/layout-backups/):
- **1-minute ring**: 10 slots, rotated on every save that changed something (the last 10 changes, ~10 min when the layout changes every minute)
- **10-minute ring**: 10 slots, rotated by separate timer, only if a save changed something since its last copy

Plus a **pinned manual save** (`window-layout-manual.json`) that autosave never touches.

## Hotkeys

| Keys | Action |
|------|--------|
| **fn+ctrl+option+delete** | Manual save (pinned, survives autosave) |
| **fn+ctrl+option+shift+delete** | Manual restore (pinned save, fallback to autosave) |

## Key files

| File | Role |
|------|------|
| [lua/layout.lua](../../lua/layout.lua) | Main module: save, restore, gather, screen watcher, retry, protection |
| [lua/layoutsnap.swift](../../lua/layoutsnap.swift) | Reads the windows a save records, in its own process (binary built on first use, untracked) |
| [lua/screenswitch.lua](../../lua/screenswitch.lua) | Screen identification by spatial position, `buildScreenMap()` |
| [lua/stepper.lua](../../lua/stepper.lua) | Caffeinate watcher (sleep/wake), hotkey bindings, `triggerSave` calls |
| [data/window-layout.json](../../data/window-layout.json) | Current autosave file |
| [data/window-layout-manual.json](../../data/window-layout-manual.json) | Pinned manual save |
| [data/layout-backups/](../../data/layout-backups/) | Backup ring files |

## Timing constants

| Constant | Value | Why |
|----------|-------|-----|
| `DEBOUNCE_DELAY` | 2s | Displays appear sequentially on reconnect |
| `PERIODIC_SAVE_INTERVAL` | 60s | Frequent enough to capture Bear note moves |
| `SNAP_AX_TIMEOUT` | 1s | Longest the helper waits for one app's Accessibility answer |
| `SNAP_DEADLINE` | 4s | Apps still silent by then keep their last saved windows |
| `SAVE_TRIGGER_DELAY` | 3s | Debounce for stepper-initiated moves |
| `WAKE_SETTLE_DELAY` | 3s | Displays/windows stabilize after wake |
| `RETRY_INTERVAL` | 3s | Polling for missing windows |
| `RETRY_MAX_ATTEMPTS` | 10 | 30s total retry window |
| `PROTECTION_DURATION` | 300s | 5 min guard against autosave poisoning |

## Deep dives

| Doc | When to read it |
|-----|-----------------|
| [chronicle.md](chronicle.md) | Understanding how the system evolved and why each piece exists |
| [2026-03-22-fix-ghost-windows.md](2026-03-22-fix-ghost-windows.md) | Ghost window problem: what they are, how they corrupted restores |

## What's logged

The module logs to Hammerspoon console (check with `~/bin/hs-console.sh`). A 10-minute ring buffer is also available via `layout.dumpLog()` in the HS console.

| Event | Meaning |
|-------|---------|
| `save` | Autosave wrote a changed layout — shows window count and Bear window positions (unchanged saves log nothing) |
| `save-protected` | A window's position was substituted with ground truth during save |
| `save-skip-ghost` | A ghost window was filtered from save |
| `save-kept` | An app didn't answer the helper; its windows were kept as last saved |
| `restore` | Restore completed — shows restored/skipped counts |
| `restore-bear` | Per-Bear-window restore detail: saved position, target screen, match tiers |
| `restore-miss` | Window in save file not found in live windows |
| `screens` | Display count changed (e.g., "5 → 3") |
| `wake-check` | Wake drift check completed with no drift |
| `wake-drift` | A window was found on the wrong screen after wake |
| `wake-restore` | Auto-restore triggered by wake drift |
| `windows-reappeared` | Windows became visible after zero-window streak (screen unlock) |
| `detect-macOS` | macOS placed a window on wrong screen at reconnection |
| `protection-start` | Position protection armed (shows counts) |
| `protection-cleared` | Position protection removed |
| `retry-start` | Retry loop started for missed windows |
| `retry-restored` | A missed window was found and restored during retry |
| `retry-done` | Retry loop completed |
| `retry-cancelled` | Retry loop cancelled (new event superseded it) |
| `autosave-suppressed` | Autosave skipped because retry is in progress |
| `trigger` | A stepper-initiated save trigger (e.g., cross-display move) |
| `backup-1m`, `backup-10m` | Ring buffer rotation |

## Related

- ==🟢**[L006/screenmaps](subfeatures/screenmaps/)**== — the layout's digital twin: each display config's last layout as a map of its displays and as bulleted lists, updated with every save that changes something ([page](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/))
- **[F010 — sync-display-names-in-Lunar](../../features/F010-sync-display-names-in-Lunar/)** — syncs Lunar brightness app names after display reconnection, using the same `buildScreenMap()` infrastructure
- **[L005 — weekly-updater-of-Bear-shortcuts](../L005-weekly-updater-of-Bear-shortcuts/)** — Bear hotkeys generate `triggerSave` calls after summon/unsummon
