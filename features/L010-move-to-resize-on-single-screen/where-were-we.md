# L010 — where were we

> Snapshot for resuming after a break. Captures what's shipped, what's deferred, what's haunted, and how to pick up. Last updated: 2026-04-30.

## v0.4 — pared back to mechanical shove (2026-04-30)

==🟣Direction change==: stretch-back was removed. The kinesthetic metaphor was nice in theory but in daily use, ==🔴moving back almost never wanted regrowth==. Shift+arrow already covers intentional resize-from-edge, so the "stretch back" half of the model paid persistence/divergence/restore complexity for an interaction that was usually unwanted.

==🟢Current model==: the [shove](#current-state--whats-shipped) math from v0.1 stayed, applied one-shot per keypress with no stored state. Press past edge → off-screen overflow becomes shrink. Press back → it's a normal slide. Floor cap still per-app.

==🔴Removed==: virtual-frame state, disk persistence ([data/move-to-resize-on-single-screen.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/move-to-resize-on-single-screen.json) deleted), divergence detection, `bumpVirtual` (B4), `resetWithNotice` (mousemove onDragStart hook), eager Bear restore (`APP_PRESERVE_ON_CLOSE`), title-rename migration, fresh-window heuristic, green stretch flash, the `withReset` wrapper across sibling ops in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua), and the L010-reset path on fn+cmd+Del.

==🔵Module size==: ~585 lines → ~175 lines.

==🟣If we ever want stretch-back again==: the full v0.1–v0.3.5 implementation is preserved in git history at commit `7939d28` (L010 pause point). The design lineage (previous-vs-virtual parameters, virtual frame mental model) below is kept verbatim as historical record; the v0.1-v0.3.5 sections describe a system that ==🔴no longer matches the code==.

## Contents

- [Current state — what's shipped](#current-state--whats-shipped)
- [Deferred — what's not done](#deferred--whats-not-done)
- [Known wrinkles to revisit](#known-wrinkles-to-revisit)
- [L011 — Bear-restore-on-reopen](#l011--bear-restore-on-reopen)
- [How to resume](#how-to-resume)
- [Files of record](#files-of-record)

## Current state — what's shipped

L010 is **already useful** for laptop-mode juxtaposing on single-screen. Daily-driver works:

- ==🟢v0.1== — fused move-and-shrink on the no-modifier fn+arrow keys, gated by `#hs.screen.allScreens() == 1`, with reset hooks across all sibling ops (snap-to-edge, maximize, half/third, shrink, move-to-display) and a B4 special case (shift+arrow resize preserves absorbed via `bumpVirtual`).
- ==🟢v0.2== — visual feedback split between two surfaces:
  - **Screen-edge red/green flash** for squeeze/stretch, reusing `flashEdgeHighlight` with a color override.
  - **Window-border red flash** for divergence/reset (fn+cmd+Del, or proactive on fn-drag start via `mousemove.onDragStart` hook). Non-fn-drag external moves (BTT, system shortcuts) self-heal silently.
- ==🟢v0.3== — disk persistence in `data/move-to-resize-on-single-screen.json`, debounced 5s, 30-day prune, app+title key with rename migration. Reset clears persistent too. Fresh-window heuristic guards against stale entries on Chrome-tab-style reuse.
- ==🟢v0.3.5== — eager Bear restore via `hs.window.filter` for `APP_PRESERVE_ON_CLOSE` apps. Fires on `windowCreated` and on init for already-open windows.
- ==🟢bonus side-fixes==:
  - clamp shift+arrow shrink to per-app/project floor (was unbounded; could shrink to a title bar)
  - kitty floor: 900×400 → 500×200
  - L009 keymap noise: removed the `os.date()` timestamp that was making every regen byte-different and defeating writeFile dedupe; rcmd presses no longer spam the console
  - `[shove]` log silenced on pure slides (no absorption before or after) — only fires when something interesting happened

==🟣21/21 unit tests pass==. Verify with:
```
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'return hs.inspect(_G.ofsr.selfTest())'
```

## Deferred — what's not done

### v0.4 — multi-screen transition handling

Per the [plan](plan.md#v04--multi-screen-safety): when `screenCount` transitions away from 1 (external monitor plugged in), iterate windows with virtual state and either:
- Auto-regrow if window moved to another display
- Preserve in place if still on the built-in display

In practice, this is the lowest-priority remaining item — single-screen is the only mode where ofsr fires anyway, and plug/unplug just dormant-routes through vanilla WinWin until you unplug. State stays valid (frames don't get stranded) because the dispatcher gate prevents shove on multi-screen. The risk is mostly cosmetic: a window's persistent `virtualFrameRel` is screen-relative; if you unplug to a screen of different aspect, the relative coords scale weirdly. ==🟡acceptable for now==.

### L011 — full implementation

==🔵[features/L011-Bear-restore-on-reopen/README.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L011-Bear-restore-on-reopen/README.md)== has the design. Code is ==🔴not yet written==. Lives inside `lua/bear-hud.lua` as an extension to the existing per-note `positions` schema (caret + scroll today, frame added). Notes from the design call:

- Schema: add `frame` field to `positions[key]` so each note stores `{caret, scroll, frame}`. Old entries without `frame` keep working (additive).
- Save trigger: Bear window loses focus / closes — capture frame in relative coords.
- Restore trigger: Bear window appears with a known title — apply frame via `setFrame` (then caret/scroll on text area).
- Coordination with L010: ==🟢L010's eager restore runs first==. L011 checks `ofsr.getVirtual(win)` — if non-nil, L010 already seeded a session entry for this window, so L011 skips the frame restore (the squeezed visible frame already encodes the correct position).
- Title-rename migration: mirror screenmemory + L010 pattern.
- File: `data/bear-hud-positions.json` (already exists, schema becomes a strict superset).

When picking up: read the L011 README, then extend `bear-hud.lua` step by step. The hooks for window focus/close already exist in bear-hud's existing eventtaps.

## Known wrinkles to revisit

### W1 — Fresh-window heuristic for non-Bear apps may be too aggressive

**Symptom**: after squeeze→reload→fn-arrow on a kitty window, sometimes the persistent entry is dropped as `looks fresh` even when the window stayed where it was. Visible in console as:
```
[ofsr-restore] "kitty:..." dropped — live=AxB differs from restored=CxD (looks fresh, app not preserved)
```

**Why**: the heuristic compares `live:frame()` to the persistent's `clampToScreen(restoredVirtual, screen)` with a 10px tolerance. If they differ by more, drops. For non-Bear apps where the user manually resized between squeeze and reload, the live frame drifts and the heuristic drops on first shove.

**Possible fixes** when revisiting (logging now shows dimensions, so when you return you can see exactly how much they differ):
1. Widen the tolerance (e.g., 50px) — accept moderate drift as "still squeezed."
2. Make the drop case stricter — only drop if live looks like a default/fresh window (e.g., live.w > 0.8 × screen.w).
3. Add kitty to `APP_PRESERVE_ON_CLOSE` — stop dropping for kitty entirely (trade-off: a fresh kitty window with a colliding title would get pre-squeezed).

==🟣No decision yet==. The current design errs on the side of "drop stale" which protects against Chrome-tab cases but inconveniences kitty across reload.

### W2 — Window IDs change on Hammerspoon reload

Session memory uses `win:id()` which is fresh on reload. The persistent map (keyed by `app\ntitle`) bridges across reloads via lazy restore on first shove. ==🟢working as intended==, just worth knowing when debugging.

### W3 — Persistent file write is debounced 5s

If you squeeze and reload within 5 seconds, the latest squeeze isn't on disk yet. Reload picks up an older state (or no state if first squeeze). Either wait 5s before reloading, or accept the lag.

### W4 — Disk write needs an integration test

Not exercising disk I/O in `selfTest`. If `hs.json.encode` ever changes shape or `io.open` semantics drift, current tests wouldn't catch it. ==🟡add a small integration test in v0.4 work==.

## L011 — Bear-restore-on-reopen

When picking up L011, the work is:

1. Read the L011 README for the "why Bear is special" framing and the Bear↔Chrome↔Kitty contrast table.
2. Extend `lua/bear-hud.lua`'s `positions[key]` to include `frame` (relative coords).
3. Save frame on Bear window focus-loss / close.
4. Restore frame on Bear window appear, **after** checking `ofsr.getVirtual(win) == nil` (defer to L010 if it already restored).
5. Existing rename-migration logic in bear-hud probably needs a touch to migrate `frame` along with `caret`/`scroll`.
6. Add `data/bear-hud-positions.json` schema migration shim (old entries without `frame` field).

Estimate: ~80 lines added to `bear-hud.lua`, no new file.

## How to resume

Pick a thread:

- **Resume L010 polish** → start with [W1](#w1--fresh-window-heuristic-for-non-bear-apps-may-be-too-aggressive). Look at logs from real usage to decide which fix.
- **Build L011** → read the [L011 README](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L011-Bear-restore-on-reopen/README.md), then extend `bear-hud.lua` per the L011 plan above.
- **Ship L010 v0.4** → see [plan.md v0.4 section](plan.md#v04--multi-screen-safety). Lowest priority.

Quickest sanity check on resume:
```bash
~/bin/hs-reload.sh
~/bin/hs-console.sh 5    # confirm [ofsr] init line shows persisted=N, eagerWatch=on
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'return hs.inspect(_G.ofsr.selfTest())'
# expect { pass = 21, fail = 0 }
```

## Files of record

| File | Role |
|------|------|
| ==🔵[features/L010-move-to-resize-on-single-screen/design.md](design.md)== | Behavior contract, mental model, shoving metaphor |
| ==🔵[features/L010-move-to-resize-on-single-screen/plan.md](plan.md)== | Phased implementation plan (v0.1–v0.4) |
| ==🔵features/L010-move-to-resize-on-single-screen/where-were-we.md== | This file — resume snapshot |
| ==🔵[features/L011-Bear-restore-on-reopen/README.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L011-Bear-restore-on-reopen/README.md)== | L011 design (the dual of L010) |
| ==🔵[lua/move-to-resize-on-single-screen.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/move-to-resize-on-single-screen.lua)== | Implementation: state, math, ops, persistence, eager Bear restore |
| ==🔵[lua/stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)== | Dispatcher + reset hooks + ofsr.init wiring |
| ==🔵[lua/mousemove.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/mousemove.lua)== | onDragStart hook for proactive virtual-frame drop |
| ==🔵data/move-to-resize-on-single-screen.json== | Runtime: persistent virtual frames (gitignored) |

==🟣L010 is daily-driver-grade as of 2026-04-26.== Take a break, you earned it.
