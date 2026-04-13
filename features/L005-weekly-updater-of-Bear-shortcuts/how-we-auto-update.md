# How We Auto-Update Bear Week Variables

## Contents

- [Decision](#decision)
- [Why not launchd?](#why-not-launchd)
- [Why Hammerspoon is the right scheduler](#why-hammerspoon-is-the-right-scheduler)
- [What went wrong (twice)](#what-went-wrong-twice)
- [What protects us now](#what-protects-us-now)

---

## Decision

We schedule the [L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts) weekly update via Hammerspoon, calling [update-bear-weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/update-bear-weeks.py) through three triggers in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua):

1. ==🟢Synchronous on-load== (`hs.execute`) — runs before bear-hud binds hotkeys, so a single reload picks up the new week
2. ==🟢Monday 00:01 timer== (`hs.timer.doAt`) — fires `updateBearWeeksAsync()`, reloads if changed
3. ==🟢Wake handler== (`hs.caffeinate.watcher`) — catches Monday updates when the laptop was asleep at midnight

The script is idempotent — extra runs are harmless.

## Why not launchd?

The original implementation used a launchd plist (`~/Library/LaunchAgents/com.stepper.update-bear-weeks.plist`) to run the Python script every Monday at 7am. It failed with:

```
Operation not permitted
```

### Root cause: macOS TCC and CloudStorage

==🔴`~/Library/CloudStorage/` is protected by `kTCCServiceFileProviderDomain`== — a dedicated TCC (Transparency, Consent, and Control) service for Apple's File Provider framework. When Apple forced Dropbox/Google Drive/OneDrive off kernel extensions onto the File Provider framework, all sync roots moved to `~/Library/CloudStorage/`. Files there can be virtual placeholders that trigger downloads on access, so Apple gates them with their own TCC category — separate from Desktop/Documents/Downloads protections.

TCC uses an **attribution chain** to decide who's "responsible" for a file access:

- **Terminal**: Terminal.app has Full Disk Access, so everything spawned from Terminal inherits it. That's why `python3 update-bear-weeks.py` works fine from the command line.
- **launchd agents**: ==🔴There is no responsible GUI app in the chain.== Shell scripts have no bundle ID, no code signature, and can't receive TCC grants. It doesn't matter which interpreter runs the script (`/bin/bash`, `/usr/bin/python3`) — the access is denied because there's no app to attribute it to.

### Symlinks don't help

TCC resolves symlinks and checks the **real path**. A symlink at `~/.config/bear-notes.jsonc` pointing into CloudStorage would still be blocked. Apple explicitly patched this class of bypass (CVE-2024-44131 in macOS Sequoia).

### Folders that DO work for launchd

Anything not on Apple's hard-coded protected list: `~/.config/`, `~/bin/`, `~/Library/Application Support/`, `/tmp/`, etc. The restricted list is: Desktop, Documents, Downloads, CloudStorage, removable/network volumes, and app-specific data (Mail, Messages, Safari).

### Workarounds we considered and rejected

| Approach | How it works | Why we rejected it |
|----------|-------------|-------------------|
| **Automator app wrapper** | Create an .app that runs the script, grant it Full Disk Access | Hidden dependency — new Mac setup requires manual FDA grant, macOS updates can reset it |
| **Compiled Mach-O wrapper** | Tiny C binary that `execv()`s the script, granted FDA | Same manual grant fragility |
| **Move files out of CloudStorage** | Put bear-notes.jsonc in ~/.config/ | Breaks project cohesion — the file belongs with the Hammerspoon config in Dropbox |
| **Symlink from non-restricted path** | Symlink ~/.config/bear-notes.jsonc → CloudStorage | TCC resolves symlinks, still blocked |

## Why Hammerspoon is the right scheduler

- Hammerspoon is the application that *uses* [bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc) — having it keep its own config fresh is natural
- It already has `kTCCServiceFileProviderDomain` permission (granted through normal macOS consent)
- Zero external dependencies — no launchd plist, no FDA grants, no wrapper apps
- Self-contained in the stepper config that's already always running
- Survives macOS updates and new machine setup (just install Hammerspoon + grant accessibility)
- `hs.task` spawns the Python script as a child process, inheriting Hammerspoon's TCC grants

==🟣However, "runs inside Hammerspoon" does NOT mean "just works"== — Lua's garbage collector and `dofile()` scoping have bitten us twice. See [What went wrong](#what-went-wrong-twice) below.

---

## What went wrong (twice)

Choosing Hammerspoon over launchd solved the TCC problem, but introduced Lua-specific pitfalls that caused the updater to silently fail every Monday for weeks.

### Bug 1: Wrong path (weeks 14-16, 3 weeks broken)

==🔴`update-bear-weeks.py` had three `..` parent levels instead of two==, resolving to `hammerspoon/` instead of `hammerspoon/stepper/`. The script looked for a nonexistent `bear-notes.jsonc`, raised `FileNotFoundError`, and the error was swallowed by the async callback.

**Fix** (2026-04-07): Corrected path, added sync on-load, refactored for testability, added 14 TDD tests including `TestPathResolution` that catches this exact bug. See [changelog](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-07-fix-L005-week-updater.md).

### Bug 2: Timer and watcher garbage-collected (week 16)

==🔴The April 7 fix introduced `hs.timer.doAt()` and `hs.caffeinate.watcher` without storing their return values.== Since [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) runs via `dofile()`, top-level locals go out of scope when the chunk returns to `init.lua`. Lua's GC collected both objects, silently killing the Monday timer and the wake handler. This is the same bug class as the [stale-border-timer-gc fix](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-03-30-stale-border-timer-gc.md) from March 30 — that lesson was documented 8 days before the updater was added but wasn't applied.

==🟣Key insight: `local` variables in a `dofile()` chunk do NOT prevent GC.== Unlike [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) (whose module-level locals survive because they're captured as upvalues by returned closures), stepper.lua has no return table. Only `_G` globals are safe.

**Fix** (2026-04-13): Stored both objects on `_G._stepper`, added startup GC self-test, added 3 Hammerspoon integration tests, wrote [hs-test-week-updater.sh](openfile:///Users/sara/bin/hs-test-week-updater.sh). See [changelog](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-04-13-fix-L005-timer-watcher-gc.md).

---

## What protects us now

The updater now has layered defenses — each previous failure mode has a test that catches it:

| Failure mode | Test that catches it |
|---|---|
| Wrong path to `bear-notes.jsonc` | `TestPathResolution` (3 tests) |
| Bad week computation or wraparound | `TestComputeWeeks` (5 tests) |
| Regex doesn't update values / breaks comments | `TestUpdateContent` (4 tests) |
| File not written or written when not needed | `TestEndToEnd` (2 tests) |
| Timer GC'd after `dofile()` returns | `TestHammerspoonIntegration.test_week_timer_survives_gc` |
| Watcher GC'd after `dofile()` returns | `TestHammerspoonIntegration.test_sleep_watcher_survives_gc` |
| GC self-test not running on load | `TestHammerspoonIntegration.test_startup_gc_selftest_logged` |

==🔵Run `~/bin/hs-test-week-updater.sh` anytime== to check the full pipeline (7 checks including live GC survival via IPC).

==🔵Every Hammerspoon reload prints `[weekUpdate] GC self-test: timer=alive watcher=alive`== to the console. If it ever says `DEAD`, the fix has regressed.
