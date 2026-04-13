# Developer Guide

==🟣Gotchas, dependencies, and hard-won lessons from building on Hammerspoon.==

## Contents

- [Dependencies](#dependencies)
- [Lua GC and dofile()](#lua-gc-and-dofile)
- [Retina subpixel rounding](#retina-subpixel-rounding)
- [fn key workaround](#fn-key-workaround)
- [hs.canvas custom fields](#hscanvas-custom-fields)
- [TCC and CloudStorage paths](#tcc-and-cloudstorage-paths)
- [Testing and debugging](#testing-and-debugging)
- [Changelog](#changelog)

---

## Dependencies

- [WinWin Spoon](http://www.hammerspoon.org/Spoons/WinWin.html) — provides the base `stepMove` and `stepResize` primitives that stepper wraps with edge-aware behavior

---

## Lua GC and dofile()

==🔴The single most recurring source of silent failures in this project.==

[stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) is loaded via `dofile()` from `init.lua`. When `dofile()` returns, **all top-level locals go out of scope** and become eligible for Lua's garbage collector. Any `hs.timer`, `hs.caffeinate.watcher`, or other userdata stored only in a `local` will be silently collected — stopping the timer, unregistering the watcher, with no error message.

### Why `local` doesn't work in stepper.lua

```lua
-- ❌ WRONG: local goes out of scope when dofile() returns, GC collects it
local myTimer = hs.timer.doAfter(60, function() print("never fires") end)

-- ✅ RIGHT: global is rooted in _G, immune to GC
_G._stepper.myTimer = hs.timer.doAfter(60, function() print("fires!") end)
```

This was **proved empirically** with live GC tests via Hammerspoon IPC — a local timer in a `do...end` block + forced `collectgarbage()` never fires; a `_G` global survives and fires.

### Why layout.lua doesn't have this problem

[layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) returns a module table `M`. Its module-level locals survive because they're ==🟢captured as upvalues by the functions in `M`==. Since stepper.lua holds a reference to the returned table (`layout = dofile("layout.lua")`), the closures keep the locals alive. Stepper.lua itself returns nothing — it has no equivalent mechanism.

### The rule

==🔴Any `hs.*` userdata in stepper.lua that must persist (timers, watchers, eventtaps) must be stored on `_G._stepper` or another surviving global table.== Module files that return tables (layout.lua, focus.lua, etc.) can use module-level locals safely.

### Where this bit us

1. **Highlight cleanup timers** (March 2026) — `hs.timer.doAfter()` return values discarded in focus.lua, causing stuck blue borders. See [changelog](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-03-30-stale-border-timer-gc.md).

2. **[L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts) week updater** (April 2026) — Monday 00:01 timer and caffeinate wake watcher both GC'd, silently killing the entire auto-update pipeline. See [changelog](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-13-fix-L005-timer-watcher-gc.md).

---

## Retina subpixel rounding

==🔴MacBook Pro displays with non-integer scale factors== (e.g., "More Space" = 1680x1050 logical on 2880x1800 physical) cause `win:setFrame()` to round coordinates to physical pixel boundaries. Sequential frame operations (resize then move) accumulate drift.

**Fix**: After compound operations, read back `win:frame()` and re-snap to the target edge with `instant()` (sets `hs.window.animationDuration = 0` temporarily).

---

## fn key workaround

Hammerspoon's `hs.hotkey.bind()` ==🔵cannot bind to fn directly==. Instead, fn transforms arrow keys into navigation keys:

| Physical keys | Hammerspoon sees |
|---|---|
| fn + Left | `home` |
| fn + Right | `end` |
| fn + Up | `pageup` |
| fn + Down | `pagedown` |
| fn + Delete | `forwarddelete` |

However, `hs.eventtap` **can** detect fn via `event:getFlags().fn` — this is used for [mouse move](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/mousemove.lua). ==🟣Fragile: only [bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua)'s `raltWatcher` eventtap reliably sees `getFlags().fn`== from physical keyboard input. Separate `flagsChanged` eventtaps created elsewhere receive events but `fn` is always nil. Any fn-aware flag detection must route through bear-hud's watcher via `_G.shiftFirstCallback`.

---

## hs.canvas custom fields

==🔴`hs.canvas` objects are userdata and do NOT support arbitrary field assignment.== `canvas._foo = 1` throws "index invalid or out of bounds". Use a separate Lua table keyed by canvas object to store per-canvas metadata.

---

## TCC and CloudStorage paths

`~/Library/CloudStorage/` (where Dropbox syncs this project) is protected by macOS TCC. ==🔴Shell scripts spawned by launchd cannot access these paths== — they have no bundle ID and can't receive TCC grants. Hammerspoon can access them because it has `kTCCServiceFileProviderDomain` permission.

Full analysis and workaround history: [how-we-auto-update.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/how-we-auto-update.md).

---

## Testing and debugging

### Hammerspoon console

==🔵Never ask the user to check the console — read it programmatically:==

```bash
~/bin/hs-console.sh        # last 30 lines
~/bin/hs-console.sh 10     # last 10 lines
~/bin/hs-console.sh 0      # all output
```

Note: `log show --predicate 'process == "Hammerspoon"'` does NOT capture Hammerspoon's console output.

### Reload

```bash
~/bin/hs-reload.sh          # backgrounds reload, waits for ready
```

### [L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts) week updater tests

```bash
~/bin/hs-test-week-updater.sh                                    # 7-check integration suite
python3 features/L005-.../test_update_bear_weeks.py -v           # 17 unit + integration tests
```

The startup GC self-test prints `[weekUpdate] GC self-test: timer=alive watcher=alive` on every reload.

### IPC probing

Arbitrary Lua via the Hammerspoon CLI:

```bash
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
$HS -c "return type(_G._stepper.weekTimer)"    # → "userdata"
$HS -c "collectgarbage('collect'); return 'ok'" # force GC
```

---

## Changelog

All entries in [changelog/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog):

| Date | Entry |
|---|---|
| 2026-03-22 | [Fix ghost windows in layout save/restore](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-03-22-fix-ghost-windows.md) |
| 2026-03-30 | [Stale border fix: timer GC](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-03-30-stale-border-timer-gc.md) |
| 2026-04-02 | [Per-screen window position memory plan](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-02-per-screen-window-position-memory-plan.md) |
| 2026-04-04 | [Resize at max height/width screen jump fix](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-04-resize-screen-jump-fix.md) |
| 2026-04-07 | [Fix L005 week updater: wrong path](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-07-fix-L005-week-updater.md) |
| 2026-04-13 | [Fix L005 timer/watcher GC](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-13-fix-L005-timer-watcher-gc.md) |
