# L010 — move-to-resize-on-single-screen

> When on a single screen, moving a window past a screen edge absorbs the off-screen portion as a shrink; moving back regrows it. Move and shrink, fused into one gesture.

**Status:** design — not yet implemented. This doc is the source for the upcoming implementation plan.

**Created:** 2026-04-26

## Contents

- [Problem](#problem)
- [Kinesthetic metaphor: shove and stretch-back](#kinesthetic-metaphor-shove-and-stretch-back)
- [Meta: juxtaposability on small screens](#meta-juxtaposability-on-small-screens)
- [Mental model: virtual frame](#mental-model-virtual-frame)
- [Design lineage: previous-vs-virtual parameters](#design-lineage-previous-vs-virtual-parameters)
- [Activation](#activation)
- [Behavior spec](#behavior-spec)
- [Reset rules](#reset-rules)
- [Step size](#step-size)
- [Floor](#floor)
- [Visual feedback](#visual-feedback)
- [State model](#state-model)
- [Persistence](#persistence)
- [Multi-screen transitions](#multi-screen-transitions)
- [Edge cases](#edge-cases)
- [Scope: in / out](#scope-in--out)
- [Files touched](#files-touched)
- [Test plan](#test-plan)
- [Open questions](#open-questions)

## Problem

On a laptop (single screen, no external displays), the user often wants two or more windows visible at once. Today this requires **two separate gestures**: move the window toward an edge, *then* shrink it manually so it doesn't take the whole screen. The shrink is a tax — the user already expressed the spatial intent ("put this on the left half") with the move.

The frequent pain point: the user moves a window left, is surprised that half of it is hidden off-screen, and has to manually shrink. Or, anticipating that, shrinks first, then moves — two operations to express one intent.

==🟣This module fuses the two==: on a single screen, **moving a window past an edge does not push the window off-screen — it shrinks the visible portion by the off-screen amount, and remembers the offset so the window regrows when you move back.**

The user explicitly does NOT want a way to hide a window via movement. To hide, they minimize. Movement should never cross into "vanish" — it should bottom out at a minimum visible size.

## Kinesthetic metaphor: shove and stretch-back

The dominant experiential model is **shoving** the window against the screen edge: the edge resists, so the window squeezes; pull the window away from the edge and it stretches back to its original shape. The screen edge is treated as a *physical* obstacle that compresses the window rather than a clipping plane that hides it.

This metaphor is the user-facing contract. Internal implementation talks about "virtual frame" and "absorbed offsets," but log messages, comments, and any future docs should lean on **shove** / **squeeze** / **stretch back** to keep the felt model intact.

==🟣Strong signal that this design will work==: the kinesthetic metaphor was clearly visualizable before any code existed. When a feature has a felt physical analogue, the affordances tend to compose intuitively.

## Meta: juxtaposability on small screens

Two of the hardest things to recreate on a single screen, compared to vast multi-display real estate, are:

- ==🟢Summonability== — bringing a known window/document to the foreground in one gesture. Already addressed by hyperkey HUD shortcuts ([L007-hyperkey-shortcuts](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L007-hyperkey-shortcuts)) and the Bear HUD.
- ==🟢Juxtaposability== — getting two or more windows visible side by side without manually fussing with both move and resize. This is the central focus of [Stepper](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper) overall, and L010 is its single-screen-mode contribution.

L010 specifically attacks the cost of **juxtaposing two windows when neither one is currently sized to leave room for the other** — the most common laptop scenario. By fusing move and shrink into one gesture, the user expresses spatial intent ("put this on the left half") without having to negotiate sizes first.

## Mental model: virtual frame

Each window has two frames:

- **Virtual frame** — where the window *would* be if the screen were infinite. Can extend past screen bounds in any direction.
- **Visible frame** — the actual `setFrame` that gets applied. Equal to `virtualFrame ∩ screen`.

==🟢Move operations update the virtual frame; visible frame is recomputed.== Resize operations update both (rules below). The "absorbed" amount per edge is **derived**, not stored — it's just `virtualFrame.x` going negative, or `virtualFrame.x + virtualFrame.w` going past `screen.maxX`, etc.

So the only state per window is the virtual frame. Everything else is computation.

## Design lineage: previous-vs-virtual parameters

Two existing modules in this codebase already track per-thing state across operations:

- ==🔵[bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua)==: caret position and scroll position per Bear note, restored on re-visit.
- ==🔵[stepper.lua: displayUndo](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)==: original frame before a cross-screen move, restorable for one hour.
- ==🔵[screenmemory.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmemory.lua)==: per-window per-screen frame memory, session + persistent.

All three store **previous parameters** — past state preserved against the current. The virtual frame stores **hypothetical parameters** — would-be state preserved against the actual. ==🟣Same shape, opposite arrow==. The persistence patterns transfer directly.

## Activation

The module is **only active when `layout.activeCount == 1`** (i.e., the laptop is on its built-in display with no externals). All multi-screen modes use vanilla WinWin behavior unchanged.

The dispatcher logic at the bind site:
```
if layout.activeCount == 1 then ofsr.stepMove(dir) else spoon.WinWin:stepMove(dir) end
```

When `activeCount` transitions away from 1 (monitor plugged in), see [Multi-screen transitions](#multi-screen-transitions).

## Behavior spec

### B1 — Move past edge starts absorption

Window is fully on-screen, flush against an edge. User presses move-toward-that-edge.

- Virtual frame moves by `step` in that direction.
- Visible frame = `virtualFrame ∩ screen` → narrower by `step`.
- The window's edge-flush position does not change; only the opposite edge moves inward.

### B2 — Move past edge while already absorbed

Same direction press while window already has absorbed offset on that edge.

- Continue absorbing: virtual moves another `step`, visible shrinks another `step`.
- Stops when visible size hits the [floor](#floor) — partial-shrink-then-stop, no wraparound.

### B3 — Move toward an absorbed edge releases absorption first

Window has absorbed offset; user presses move-toward-that-absorbed-edge.

- Virtual frame moves by `step` in that direction (toward 0 absorbed).
- Visible frame grows by `step`, position-flush edge unchanged.
- Continue until absorbed = 0. **Next press in that direction is a normal move** (window slides away from the edge).

### B4 — Resize while absorbed preserves the offset (Q1=b)

User presses shift+arrow (resize) while absorbed.

- Visible frame changes by the resize delta, anchored per [smartStepResize](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) rules.
- ==🟢Virtual frame changes by the same delta==. Absorbed offset is preserved.
- Implication: the user can shrink while absorbed and later regrow back to the *resized* size, not the original.

### B5 — Move on the orthogonal axis is independent

Absorbed on left? Move-up still moves up normally; horizontal absorbed state is unchanged.

### B6 — Two-axis absorption

Possible. Push past bottom-right corner: virtual frame extends past both bottom and right; visible is clamped on both axes. Each axis is tracked independently.

## Reset rules

These operations explicitly clear the virtual frame: `virtualFrame := visibleFrame`.

| Operation | Modifier | Reset? |
|-----------|----------|--------|
| Step-move | *(none)* | No — this is the absorb/release operation |
| Smart step resize | shift | ==🔴No== — preserves offset (B4) |
| Move to edge | ctrl | Yes (after the snap) |
| Resize to edge | ctrl+shift | Yes |
| Toggle shrink | option | Yes |
| Toggle max-height/width, half-third, maximize, center | shift+option | Yes |
| Move to display | ctrl+option | Yes (then [transition logic](#multi-screen-transitions)) |
| Mouse drag (mousemove.lua) | fn-drag | ==🔴v2== — out of scope, but should at minimum reset on drag-end |
| External movement (BTT, app self-resize, system shortcuts) | n/a | Strict reset on detected divergence |

==🔴Divergence detection==: at the start of every absorb-capable operation, compare the live `win:frame()` to our cached `expectedVisibleFrame`. If different by more than ~5px on any axis, ==🔴assume external movement and reset== virtual = live frame, then proceed.

## Step size

Match WinWin's existing logic exactly to avoid surprise:

- `stepw = screen:frame().w / spoon.WinWin.gridparts`
- `steph = screen:frame().h / spoon.WinWin.gridparts`
- Default `gridparts = 30`. On a 1440×900 native MBP, that's `48px` and `30px` per step.

We're re-implementing step-move (per [RC3 in design conversation]), but using the same step calculation keeps muscle memory continuous when the user plugs in a monitor.

## Floor

`min(visibleW, visibleH)` is bounded below by:

```
floorW = max(200, (minShrinkSize[appName] or {w=0}).w)
floorH = max(200, (minShrinkSize[appName] or {h=0}).h)
```

- Project-wide floor: 200×200 (catches apps without an explicit minimum).
- App-specific min from [stepper.lua:minShrinkSize](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) supersedes if larger (e.g., kitty: 900×400).

==🟢Partial-shrink-then-stop==: if the next step would cross the floor, shrink to the floor exactly and stop further absorption on that axis.

## Visual feedback

==🔴RED screen border flash== when an absorb-capable operation **increases** the absorbed amount (window virtualizing — disappearing into the edge).

==🟢GREEN screen border flash== when an absorb-capable operation **decreases** the absorbed amount (window rematerializing — coming back from the edge).

- Mirror the existing snap-to-edge green border style (canvas overlay, ~150ms fade).
- Border color is the *only* visual indicator; no outline of virtual frame (since virtual frame is precisely what doesn't fit on screen, drawing it is a contradiction).
- During iteration, also emit a logged trace to the HS console: `[ofsr] win=Bear "Note Title" L+48 absL=144 visW=720`.

## State model

Two-tier, modeled on [screenmemory.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmemory.lua):

```
sessionVirtual    = {}  -- [winID] = { virtualFrame, expectedVisible, ts }
persistentVirtual = {}  -- ["app\ntitle"] = { virtualFrameRel, ts }
```

- Session table keyed by `win:id()` — exact identity within a Hammerspoon session, lost on reload.
- Persistent table keyed by `"app\ntitle"` composite — survives reload, handles app restart, requires title-rename migration.
- `virtualFrameRel` = relative coords (x/y/w/h as fractions of screen.frame), so resolution changes don't invalidate the geometry.
- `expectedVisible` is the absolute frame we *expect* to see when we read `win:frame()` next; used for [divergence detection](#reset-rules).

## Persistence

- Disk file: ==🔵[data/move-to-resize-on-single-screen.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/move-to-resize-on-single-screen.json)== (will be created).
- Debounced 5s after last change (matches screenmemory).
- 30-day auto-prune on init (matches screenmemory).
- Title-rename migration (matches screenmemory:146-165 pattern).

==🔴Stale virtual frames are an accepted cost==: if a window changes size between Hammerspoon reloads via some other tool, we'll have a stale virtual frame on disk. The first move-back will look weird; subsequent ops correct via divergence detection. The alternative — losing virtual frames on every reload — was rejected in design as causing disorienting context loss.

==🔴Fresh-window heuristic==: when we look up an `app\ntitle` and find a persistent entry whose `virtualFrameRel` extends past screen bounds, but the live window is fully on-screen, treat the persistent entry as stale and reset (don't shrink the user's freshly-opened window). This handles EC4 (app reopen with same title gets clean start).

### Per-app override: preserve-on-close

The fresh-window heuristic above is the right default for most apps. But it's wrong for apps where **window identity reliably matches document identity**, because for those apps "close and reopen" is a normal interaction pattern — not a fresh-state event.

Bear Notes is the canonical example: each Bear window is named after exactly one note, and the user (with hyperkey HUD livekeys) frequently opens-and-closes notes rather than minimize-and-restore them. Preserving the virtual frame across close-reopen for Bear is correct. By contrast:

| App | Doc-window match | Behavior |
|-----|------------------|----------|
| Bear | ==🟢Reliable== — one note per window, title = note name | Preserve virtual frame on close-reopen |
| Chrome | ==🔴Unreliable== — tabs swap window contents and titles | Fresh window heuristic applies (default) |
| Kitty | ==🔴Unreliable== — sessions hold multiple shells, multiple sessions per window via tabs | Fresh window heuristic applies (default) |

Implementation: a small allowlist in the module:

```
APP_PRESERVE_ON_CLOSE = {
  ["Bear"] = true,
}
```

When looking up a persistent entry for an app on this list, ==🟢bypass the fresh-window heuristic== — the persistent virtual frame is restored verbatim, even if the live window starts on-screen. The new window's first move toward the absorbed edge will reveal the absorbed offset (no surprise).

This list can grow as we discover other apps with reliable document-window pairing.

## Multi-screen transitions

Triggered by [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) when `activeCount` transitions away from 1.

For each window with non-trivial absorbed state at transition time:

- ==🟢If the window remains on the (now-internal) built-in display==: keep virtual frame intact. The user may unplug again and resume. (Q5=c.)
- ==🟢If the window has moved to another display==: auto-regrow visible frame to virtual frame, then clear virtual state. The new display has space; absorption isn't needed there. (Q5=a.)

When `activeCount` returns to 1, sessions resume normally — any persisted virtual frames for windows still alive will be in effect.

## Edge cases

| # | Case | Resolution |
|---|------|------------|
| EC1 | Two-axis absorption (corner push) | Tracked per-axis, independent (B6) |
| EC2 | Window narrower than screen, push past one edge, hit floor | Stop at floor, no wraparound |
| EC3 | Window wider than screen at startup (large maximize-fit) | Inherently absorbed both sides; first move releases one side, increases the other |
| EC4 | App reopen with same title | Fresh-window heuristic in [Persistence](#persistence) |
| EC5 | Window title rename mid-session | Migration logic mirrored from screenmemory |
| EC6 | Two windows with same app+title | Identity collision (acceptable, same as screenmemory) |
| EC7 | Resolution scaling change without screen-count change ("More Space" toggle) | On screen-changed event, re-clamp visible to new screen frame; virtual stays |
| EC8 | Sleep/wake | Virtual frames live in their own file, don't pollute layout autosave |
| EC9 | External tools moving the window | Strict reset on divergence |
| EC10 | Step crosses the floor | Partial-shrink-then-stop |
| EC11 | Dock and menubar | Use `screen:frame()` (excludes them); user runs dock hidden anyway |
| EC12 | Cross-display move when only one display exists | Cannot happen by definition; transition logic handles plug-in |

## Scope: in / out

**In v1:**

- Step-move via plain arrow keys (the no-modifier fn+arrow bindings).
- moveToEdge (ctrl+arrow) — participates by treating the snap as a reset.
- Disk persistence with title migration.
- RED/GREEN visual border feedback.
- Logged trace to HS console.
- Strict-reset divergence detection.
- Multi-screen transition handling.

**Deferred to v2:**

- Mouse drag absorption ([mousemove.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/mousemove.lua) integration).
- Cross-display absorption (extending the model to multi-screen, e.g., absorbing into a non-existent edge between displays).
- Per-window opt-out / per-app exclusion list.
- Configurable step size independent of WinWin.

## Files touched

**New:**

- ==🔵lua/move-to-resize-on-single-screen.lua== — module: state, math, dispatcher, visual feedback, persistence, transition handler. Estimated 250–350 lines.
- ==🔵data/move-to-resize-on-single-screen.json== — persistent state. Created at runtime.

**Modified:**

- ==🔵[lua/stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)== — load module at top; gate `stepMove` and `moveToEdge` bindings behind single-screen check; add one-line `ofsr.reset(win)` calls in 6–10 sibling operations (per [Reset rules](#reset-rules)). Estimated <30 lines of edits.
- ==🔵[README.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/README.md)== — note the single-screen-mode behavior change in the binding table.

## Test plan

Manual, on the laptop in single-screen mode unless noted.

**T1 — Basic absorb/release**
- Open Bear at default size. Press move-left until flush against left edge. Confirm window stops at edge with no absorbed yet.
- Press move-left again. Window's right edge moves inward by ~48px. ==🔴RED border flash==.
- Press move-left ~10 more times. Window keeps narrowing until it hits 200px floor. Last press: partial step.
- Press move-right. Window grows back by ~48px. ==🟢GREEN border flash==.
- Continue move-right until absorbed = 0. Next press: normal move (left edge moves right).

**T2 — Two-axis (corner push)**
- Drag a window to the bottom-right area. Press move-down past bottom, then move-right past right. Confirm both axes absorb independently.

**T3 — Resize preserves absorbed (B4)**
- Absorb a window 100px on the left. Press shift+left (smart resize, shrink). Visible width drops by ~48px.
- Press move-right (release). Confirm window grows back to the *resized* size, not the original.

**T4 — Reset operations**
- For each of: ctrl+arrow, ctrl+shift+arrow, option+arrow, shift+option+arrow combos, ctrl+option+arrow:
  - Set up an absorbed state, run the op, confirm virtual frame is reset (next move-back does a normal move, not a regrow).

**T5 — Persistence across reload**
- Absorb a window 100px. Run `~/bin/hs-reload.sh`. Press move-back. Confirm window regrows by step.
- Verify `data/move-to-resize-on-single-screen.json` has the entry.

**T6 — Fresh window after app relaunch (EC4)**
- Absorb a Bear window 100px. Quit Bear. Reopen Bear with the same note open. Confirm new window opens at native size, not pre-shrunk.

**T7 — External movement detection (EC9)**
- Absorb a window 100px. Use BTT or mouse drag to move it to a different position. Press move-toward-the-old-absorbed-edge. Confirm: ==🟢no glitch — virtual was reset on divergence==, behavior is normal step-move.

**T8 — Multi-screen transition (Q5)**
- Absorb a window 100px on internal display. Plug in external monitor.
  - If window stays on internal: confirm it stays absorbed, virtual preserved.
  - Move the absorbed window to external: confirm auto-regrow on arrival, virtual cleared.
- Unplug. Re-press move-back on a window that was absorbed pre-plug. Confirm regrow works.

**T9 — Floor (EC10)**
- Absorb a kitty window. Confirm floor = 900px (its app-specific min), not 200px.
- Absorb a generic app window. Confirm floor = 200px.

**T10 — Resolution change (EC7)**
- Toggle macOS "More Space" while a window is absorbed. Confirm visible frame re-clamps to the new screen size.

## Open questions

- **IQ1 — External-movement divergence threshold**: At the start of every absorb-capable op we compare live `win:frame()` against the `expectedVisibleFrame` we cached after the prior op. If the live frame differs by more than 5px on any axis, we conclude an external tool (BTT, mouse drag, app self-resize) moved the window and reset the virtual frame to match. ==🟢Resolved — 5px tolerance==. Step size is ~30–48px so 5px is unambiguous, and Retina rounding stays well under it.
- **IQ2 — Frame set vs border draw ordering**: Should we batch the visible-frame `setFrame` and the red/green canvas border draw, or fire them sequentially? Tentative: sequential, with `instant()` on the frame set to avoid animation lag fighting the border flash.
- **IQ3 — "Moved to another display" detection during multi-screen transition**: `win:screen():id()` comparison against a stored "home screen" probably suffices. Validate during phase 6.
- **IQ4 — Regrow style on multi-screen transition**: ==🟢Resolved — single animated `setFrame`==.

These can be resolved during implementation rather than blocking the plan.
