# Chronicle: Layout Save/Restore

> How the system evolved from a simple JSON dump to a multi-layered defense against macOS window shuffling. Each section is a chapter — a problem encountered, the fix applied, and what we learned.

## 1. The origin: macOS lost its memory (2026-02-24)

**Commit:** `0a02a27` — "Add layout.lua: save/restore/gather window positions across 5 displays"

macOS suddenly stopped remembering window positions across the 5-display setup. Diagnostics revealed the root cause: none of the 4 LG HDR 4K monitors expose unique EDID serial numbers. macOS had been using Thunderbolt port enumeration as a proxy for identity — it worked by accident until something disrupted the port order.

**First version built:**
- `layout.save()` — snapshot all visible windows to JSON
- `layout.restore()` — match windows by title, find screens by origin coordinates
- `layout.gather()` — consolidate all windows to built-in display (for undocking)
- Three-tier window matching: exact title → 40-char prefix → index fallback
- Screen matching by origin (x, y) with 2px tolerance for Retina rounding

**Key design decision:** Save z-order via `orderedWindows()` and replay it back-to-front via `focus()`. This creates a brief visual storm (each window flashes to front) but correctly restores the stacking order.

**Discovery in this session:** The "Assign to All Desktops" Mission Control option causes Bear windows to appear always-on-top — a z-order gotcha unrelated to layout but discovered during testing.

---

## 2. Automation: don't make me type it (2026-02-26)

**Commit:** `1ffd339` — "Add display-aware layout auto-save and restore-on-wake"

The manual save/restore was useful but tedious. The user wanted it automatic — but with a critical safety constraint: **auto-save must never run at fewer than 5 displays**, or it would overwrite the good desk layout with a partial/scrambled one.

**What was added:**
- `TARGET_DISPLAY_COUNT = 5` — the fundamental guard
- Periodic auto-save (initially every 5 minutes, later reduced to 1 minute)
- `onScreenChange()` with 2s debounce — detects display connect/disconnect
- Caffeinate watcher for sleep/wake events
- Restore hotkey: `fn+ctrl+alt+delete`

**Key insight discovered:** `screensDidWake` doesn't always fire when macOS keeps all 5 displays connected through sleep (5→5 transition). This was the first hint of a gap that would take weeks to fully close.

---

## 3. The identical-monitors problem (2026-03-07)

**Commit:** `6de955d` — "Fix layout restore matching wrong screens with identical monitors"

**The crisis:** After moving from 1+1 displays back to 5, "the central screen is empty and the restore seems to be a mess." The origin-based screen matching was fundamentally broken for 4 identical monitors — on every reconnect, macOS assigns different origins to the same physical screens. The resolution fallback always grabbed the first match, sending all windows to one random monitor.

**The fix: spatial position names.** Instead of matching by coordinates, save which *position* (bottom/center/top/left/right) each window was on, and on restore, find the screen currently at that position via `buildScreenMap()`. Position is computed from frame coordinates relative to the built-in display — stable because macOS preserves the display arrangement in System Settings even when it shuffles UUIDs.

**This was the pivotal fix** that made multi-display restore actually work. Everything before this was unreliable with identical monitors.

---

## 4. Stale saves and Bear notes (2026-03-09)

**Commit:** `81eb2f8` — "Add layout save triggers and debug logging for restore issues"

**The problem:** Bear notes are the most frequently moved windows (summoned/unsummoned via hotkeys, moved between displays). The 5-minute auto-save interval meant Bear positions were consistently stale at restore time — several notes ended up on wrong screens.

**The fix:**
- Reduced periodic save from 5 minutes to **1 minute**
- Added **triggered saves** (3s debounce) after `moveToDisplay()` and Bear summon/unsummon operations
- Added the **ring buffer log** (`layout.dumpLog()`) — 10 minutes of layout events for debugging

**Lesson:** Window management is high-frequency. A 5-minute save interval is an eternity when the user rearranges Bear notes dozens of times per session.

---

## 5. No backups, no safety net (2026-03-10)

**Commit:** `24923f2` — "Add layout backup rings and manual save/restore keybindings"

**The scare:** The user was about to restart and realized: (a) there's only one `window-layout.json` that gets overwritten on every save, (b) after reboot, `init()` would see 5 screens immediately and start auto-saving within 60 seconds — before apps were even open — overwriting the good layout with an empty or partial one.

**What was built:**
- **1-minute ring**: 10 rotating backups (~10 min of history)
- **10-minute ring**: 10 rotating backups (~100 min of history)
- **Manual save** (`fn+ctrl+alt+delete`): writes to a pinned file that autosave never touches
- **Manual restore** (`fn+ctrl+alt+shift+delete`): reads pinned save, falls back to autosave

**Regression caught during session:** The old restore hotkey wasn't unbound, so `fn+ctrl+alt+delete` triggered a restore instead of a save. Fixed by reloading Hammerspoon. The user established in this session: "I never reload Hammerspoon manually — Claude must always do it."

---

## 6. The zero-window save guard (2026-02-27)

**The bug:** `[layout.save] Saved 0 windows` appeared in the console. During a wake/display transition, `hs.window.orderedWindows()` returned empty, and the save wrote `[]` to the file. If the user had unplugged at that moment, the good layout would have been gone.

**The fix:** Refuse to save when 0 windows are found. Log "Skipping save — 0 windows found (display may still be waking)" instead.

**This guard later became critical** — it's what prevented the save file from being corrupted during the 27-minute screen lock in Chapter 9.

---

## 7. The Chrome timing problem and autosave poisoning (2026-03-20)

**Commit:** `ef811f2` — "Add retry + position protection to layout restore for display reconnection"

**Two independent failures observed after reconnecting 5 displays:**

**Failure 1 — Restore timing:** Chrome windows weren't visible to `orderedWindows()` when the restore ran 3 seconds after reconnection. These missed windows stayed wherever macOS placed them — typically all stacked on the primary display.

**Failure 2 — Autosave poisoning:** After a failed restore, the next autosave (within 60s) recorded the wrong positions, permanently overwriting the correct layout. Future restores then applied the wrong positions. This was the most insidious failure because it was **self-reinforcing** — each bad restore made the next one worse.

**The fix — two new mechanisms:**

**Retry loop:** Polls for missed windows every 3s for 30 seconds. Uses only exact-title and prefix matching (no index fallback — too risky with windows still appearing). Suppresses autosave during retry.

**Position protection:** After reconnection, all saved entries become "ground truth" for 5 minutes. If autosave runs and a window is on a different screen than saved, the save file gets the ground-truth position. This breaks the poisoning cycle — even if macOS hasn't moved the window back yet, the save remains correct.

**User frustration in this session:** "This was such a snafu, and very disorienting." The initial advice to bootstrap via manual restore was wrong — the manual save was weeks old with wrong titles, and index fallback made things worse.

---

## 8. Ghost windows: the invisible corrupters (2026-03-22)

**Commit:** `41337c7` — "Filter ghost windows from layout save and prevent restore from touching minimized/hidden windows"

**Three anomalies after a manual restore:**
1. A **minimized** Chrome window got unminimized — `allWindows()` exposed it as a Tier 3 candidate
2. A **hidden** Figma app became visible — `focus()` in z-order replay unhid it
3. A Bear window **shrank to 300x250** — a ghost Bear entry (tooltip at 53x48) was index-fallback-matched to it

**Root cause:** `orderedWindows()` captures transient UI elements (Bear tooltips, Chrome find bar) as if they're real windows. On restore, these ghost entries' tiny frames got applied to real windows via index fallback.

**Three-layer fix:**
1. `isGhostWindow()` filter on save: rejects non-standard, <100x100, or newline-in-title windows
2. `orderedWindows()` instead of `allWindows()` on restore: excludes minimized/hidden windows
3. Size guard (100x100) on Tier 3 index fallback: defense-in-depth for old save files

See [2026-03-22-fix-ghost-windows.md](2026-03-22-fix-ghost-windows.md) for the detailed writeup.

---

## 9. The screen lock gap (2026-03-23)

**The scenario:** User locked screen, went for a break (~27 minutes). Came back, unlocked, and found w12work on the top display instead of right. "It's super jarring that window restore is still this bad after so many iterations."

**What the logs revealed:**

```
17:52:29  Last good save — w12work@right
17:53:09  loginwindow warning (screen locked)
17:53:29  Skipping save — 0 windows found    ← correct, guard working
  ...     (38 minutes of 0-window saves)
18:20:26  screens: 5 → 5                     ← screen change, but count unchanged
  ...     (still 0 windows)
~18:31    User unlocks — windows reappear with macOS-shuffled positions
18:32:29  save: w12work@top                  ← WRONG! First autosave records bad positions
```

**The gap:** Three restore triggers existed, but none caught this:
- **Display reconnection** — screens stayed at 5 the whole time (no 5→N→5 transition)
- **`screensDidWake`** — never fired (screen lock ≠ system sleep)
- **`onWake()` drift check** — was never called

**The fix: zero-window streak detection.** `autoSave()` now tracks consecutive cycles where `orderedWindows()` returns 0. When windows reappear after a streak (the 0→N transition), it calls `onWake()` for drift detection instead of blindly saving. This closed the last gap.

**Key distinction learned:**

| Event | `screensDidWake` fires? | `orderedWindows()` returns 0? | Screen count changes? |
|-------|:-:|:-:|:-:|
| System sleep/wake | Yes | Briefly | Sometimes |
| Display sleep (idle timeout) | Sometimes | Yes, during lock | No |
| Screen lock (manual) | **No** | **Yes, entire duration** | No |
| Display reconnection | No | Briefly | Yes (5→N→5) |

The zero-window streak catches the screen lock case that all other detection methods miss.

---

## Lessons learned

1. **Identical hardware defeats macOS.** Without unique serials, macOS can't tell displays apart. Spatial position is the only stable identifier.

2. **Three restore triggers are needed.** Each macOS disruption scenario fires different (or no) system events. You need: screen count transition, caffeinate wake, and zero-window reappearance.

3. **Autosave is both savior and threat.** It preserves the correct layout — but if it runs after macOS shuffles windows and before restore, it permanently poisons the save. Position protection is essential.

4. **Ghost windows corrupt silently.** Transient UI elements (tooltips, find bars) look like real windows to the accessibility API. Without size/standard filtering, they create phantom save entries that consume real windows during restore.

5. **Retry is essential for Chrome.** Chrome's windows appear late to the accessibility API. Without the retry loop, Chrome windows are consistently missed on reconnection.

6. **The save file must never be empty.** The zero-window guard and the display-count guard are the two most important lines of defense.
