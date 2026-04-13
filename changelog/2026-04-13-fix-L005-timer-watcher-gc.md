# Fix: [L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts) timer and watcher silently garbage-collected

**Date**: 2026-04-13

## Contents

- [Symptom](#symptom)
- [Root cause](#root-cause)
- [Why local didn't help](#why-local-didnt-help)
- [Fix](#fix)
- [Verification](#verification)
- [Files changed](#files-changed)

---

## Symptom

==🔴Monday morning, Bear hotkeys (Hyper+D/W/T) still pointed at week 15 instead of week 16.== The [previous fix](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-07-fix-L005-week-updater.md) (April 7) added three update triggers — synchronous on-load, Monday 00:01 timer, and wake handler. All three failed:

- ==🔴No `[weekUpdate]` message in the entire console== — the on-load sync ran Saturday (correctly, week was still 15), but Hammerspoon wasn't reloaded Monday
- ==🔴No `[stepper] Wake detected` message== — the caffeinate watcher was dead
- ==🔴No Monday timer fire== — the timer was dead

---

## Root cause

==🔴Lua garbage collection.== The `hs.timer.doAt()` and `hs.caffeinate.watcher` objects were created at the top level of [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) without saving their return values to persistent references. Once `dofile("stepper.lua")` returned to `init.lua`, both objects became eligible for GC. Lua's collector eventually reaped them, silently stopping the timer and unregistering the watcher.

==🟣This is the same bug class as the [stale-border-timer-gc fix](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-03-30-stale-border-timer-gc.md) from March 30== — that fix stored `hs.timer.doAfter()` references in focus.lua/stepper.lua for highlight cleanup. The lesson was documented 8 days before the week updater was added, but wasn't applied to its timer and watcher.

---

## Why `local` didn't help

The first attempted fix was `local weekTimer = hs.timer.doAt(...)`. ==🔴This is wrong.== `stepper.lua` runs via `dofile()` — top-level locals go out of scope when the chunk returns. Unlike [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) (whose module-level locals survive because they're captured as upvalues by returned closures), stepper.lua has no return table to keep locals rooted.

This was proved with live GC experiments via Hammerspoon IPC:

```lua
-- LOCAL: timer GC'd, never fires
do local t = hs.timer.doAfter(3, function() print("survived") end) end
collectgarbage("collect")
-- ❌ callback never runs

-- GLOBAL: timer survives GC, fires
_G._t = hs.timer.doAfter(3, function() print("survived") end)
collectgarbage("collect")
-- ✅ callback runs after 3s
```

---

## Fix

==🟢Store both objects on `_G._stepper`== — a global table that's immune to GC and accessible via IPC for testing:

```lua
_G._stepper = {}
_G._stepper.weekTimer = hs.timer.doAt("00:01", "1d", function() ... end)
_G._stepper.sleepWatcher = hs.caffeinate.watcher.new(function(event) ... end)
_G._stepper.sleepWatcher:start()
```

==🔵Added a startup GC self-test== that runs on every Hammerspoon reload — forces two GC cycles and verifies both objects are still `userdata`. Prints to console:

```
[weekUpdate] GC self-test: timer=alive watcher=alive
```

If this ever prints `DEAD`, the fix has regressed.

==🔵Added live integration test script== — [hs-test-week-updater.sh](openfile:///Users/sara/bin/hs-test-week-updater.sh) runs 7 checks covering: Python script, bear-notes.jsonc correctness, 17 unit tests, and GC survival via IPC. One command to answer "will next Monday work?"

==🔵Added 3 Hammerspoon integration tests== to [test_update_bear_weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/test_update_bear_weeks.py) (now 17 total): `test_week_timer_survives_gc`, `test_sleep_watcher_survives_gc`, `test_startup_gc_selftest_logged`.

---

## Verification

```bash
# All 7 integration checks pass:
~/bin/hs-test-week-updater.sh

# All 17 unit + integration tests pass:
python3 features/L005-.../test_update_bear_weeks.py -v

# Console shows on every reload:
[weekUpdate] GC self-test: timer=alive watcher=alive

# IPC probe returns "userdata" after forced GC:
hs -c "collectgarbage('collect'); return type(_G._stepper.weekTimer)"
```

---

## Files changed

- [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua): `_G._stepper` globals for timer + watcher, startup GC self-test
- [test_update_bear_weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/test_update_bear_weeks.py): 3 new `TestHammerspoonIntegration` tests (14 → 17 total)
- [hs-test-week-updater.sh](openfile:///Users/sara/bin/hs-test-week-updater.sh): New — 7-check live integration test script
