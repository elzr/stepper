# L010 — Implementation plan

> Phased build of [move-to-resize-on-single-screen](design.md), structured as four release-train versions. Each version is a clean stopping point — committable, individually testable, and independently reversible.

**Status:** plan — pending review. Implementation has not started.

**Companion doc:** [design.md](design.md)

## Contents

- [Approach](#approach)
- [v0.1 — Bare bones, in-memory only](#v01--bare-bones-in-memory-only)
- [v0.2 — Polish](#v02--polish)
- [v0.3 — Persistence](#v03--persistence)
- [v0.4 — Multi-screen safety](#v04--multi-screen-safety)
- [Post-implementation](#post-implementation)
- [Risk register](#risk-register)
- [Naming conventions for code](#naming-conventions-for-code)

## Approach

**Release-train phasing.** The user will test on the laptop in single-screen mode after each version ships. Phases within a version are committed individually but expected to land together. Versions are committed as units and act as "good places to stop" if reality intervenes.

**Why this ordering?** v0.1 ships the core fused move-and-shrink behavior with no persistence and no visual flourish — pure proof of concept. v0.2 adds the kinesthetic visual feedback (RED/GREEN borders) and robustness against external tools. v0.3 adds disk persistence and the Bear special case. v0.4 closes the loop on multi-screen safety. **The user can stop after any version and have a working, useful feature.**

**The shoving metaphor is the felt model.** Log messages, comments, and user-visible strings should lean on **shove / squeeze / stretch** — not "absorb / virtual / clamp". Internal code can use the technical names; surface text uses the metaphor.

**No code yet — this plan is for review first.**

## v0.1 — Bare bones, in-memory only

==🟢Goal==: prove the fused move-and-shrink works end to end on a laptop. State lives in memory only; reload wipes it.

### Phase 1 — State module + math

**Creates:** ==🔵lua/move-to-resize-on-single-screen.lua==

**Module shape:**

```
local M = {}
M.sessionVirtual = {}    -- [winID] = { virtualFrame, expectedVisible, ts }
M.persistentVirtual = {} -- ["app\ntitle"] = { virtualFrameRel, ts }   -- written in v0.3

-- Pure helpers
function M.clampToScreen(virtualFrame, screen) ... end
function M.computeMove(virtualFrame, dir, step, screenFrame, floor) ... end
function M.computeResize(virtualFrame, dir, step, screenFrame, floor) ... end

-- State helpers
function M.get(win) ... end          -- session lookup; returns virtualFrame or nil
function M.set(win, virtualFrame) ... end
function M.reset(win) ... end        -- clear session entry; virtual := visible
function M.shove(win, dir) ... end   -- the main public op
function M.stretch(win, dir) ... end -- counterpart, same physical key, opposite direction state

return M
```

==🟢Pure functions are the heart.== `computeMove` takes the current virtual frame, direction, step, and screen, and returns `{newVirtualFrame, deltaAbsorbed}`. No window handle touched. Unit-testable from the HS console: `hs -c 'return hs.inspect(require("move-to-resize-on-single-screen").computeMove(...))'`.

**Step calculation** mirrors WinWin:
```
stepw = screenFrame.w / 30   -- match spoon.WinWin.gridparts
steph = screenFrame.h / 30
```

**Floor calculation:**
```
floorW = math.max(200, (minShrinkSize[appName] or {w=0}).w)
floorH = math.max(200, (minShrinkSize[appName] or {h=0}).h)
```

`minShrinkSize` is reused from [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua); the module imports it via a small accessor or accepts it via init.

**Verification (local):** `hs -c` calls into pure functions with synthetic frames; assert outputs.

**Risk:** ==🟣low== — no integration yet, no I/O. Worst case is a math bug, easy to spot.

**Estimated:** ~150 lines.

---

### Phase 2 — Dispatcher + step-move

**Modifies:** ==🔵[lua/stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)==

**Changes:**

1. `dofile(...)` the new module near the top.
2. Replace the no-modifier arrow bindings (lines 850–853) with a dispatch:
   ```
   local function dispatchStepMove(dir)
     if layout.activeCount == 1 then
       ofsr.shove(focusedWin(), dir)
     else
       spoon.WinWin:stepMove(dir)
     end
   end
   ```
3. The `ofsr.shove` function:
   - Reads live frame, compares to `expectedVisibleFrame` (skipped in v0.1 — that's phase 5).
   - Calls `computeMove`, gets new virtual frame.
   - Computes new visible frame = `clampToScreen(newVirtual)`.
   - Calls `win:setFrame(newVisibleFrame)` with `instant()` for tiny moves.
   - Stores `{virtualFrame, expectedVisible}` in session state.
   - Emits a console trace: `[shove] win="Bear:Note" dir=left absL=144 visW=720 (squeezed +48)`.

**Verification:**

- T1, T2, T5 (release), T6 (basic move-back) from the [design test plan](design.md#test-plan).
- Test trace appears in `~/bin/hs-console.sh`.
- ==🔴Single-screen only==: plug in monitor, confirm vanilla WinWin behavior returns.
- Reload Hammerspoon (`~/bin/hs-reload.sh`); confirm no errors.

**Risk:** ==🟡medium== — first integration, first place a binding could misfire. The `layout.activeCount == 1` gate is the main correctness check.

**Estimated:** ~50 lines of edits in stepper.lua + ~80 lines added in the module.

---

### Phase 3 — Reset hooks across sibling operations

**Modifies:** ==🔵[lua/stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)==

==🟢One-line `ofsr.reset(win)` calls== inserted at the end of:

| Operation | Function name | When to reset |
|-----------|---------------|---------------|
| Move to edge | `moveToEdge` | After snap |
| Resize to edge | `resizeToEdge` | After snap |
| Toggle shrink | `toggleShrink`, `toggleShrinkOrMax` | After change |
| Cycle half/third | `cycleHalfThird` | After change |
| Toggle max-height/width | `toggleMaxHeight`, `toggleMaxWidth` | After change |
| Maximize | `toggleMaximize` | After change |
| Center | `toggleCenter` | After change |
| Move to display | `moveToDisplay` | After move (then transition logic in v0.4) |

==🔴Smart step resize is special (B4)==: `smartStepResize` does NOT call `ofsr.reset`. Instead, it calls `ofsr.bumpVirtual(win, dx, dy, dw, dh)` — preserves absorbed offset by applying the same delta to the virtual frame.

**Verification:**

- T4 from the design test plan: for each operation, set up an absorbed state, run the op, confirm next move-back does a normal slide (no regrow).
- T3: resize while absorbed, then move-back; confirm regrow to *resized* size.

**Risk:** ==🟡medium== — easy to miss an op or insert reset at the wrong point. Walk through every binding, not just the obvious ones.

**Estimated:** ~10 lines of edits in stepper.lua + `bumpVirtual` helper in module (~15 lines).

---

### v0.1 stop point

==🟢User can shove a window left and watch it squeeze, stretch back by moving right==. State lives only in memory; reload resets all. No visual feedback yet — only console trace. No external-movement detection.

**Test list before declaring v0.1 done:** T1, T2, T3, T4 from [design.md test plan](design.md#test-plan). Plus: confirm zero behavioral change in multi-screen mode (plug in monitor, verify all bindings unchanged).

**If something feels wrong here, stop.** Don't proceed to v0.2 with a confused core.

## v0.2 — Polish

==🟢Goal==: make the kinesthetic metaphor visible and harden against external tools.

### Phase 4 — Visual feedback (red/green canvas border)

**Modifies:** the L010 module.

A canvas border like the existing snap-to-edge green flash. Two variants:

- ==🔴RED== — fired when an op increases the absorbed amount (squeezing).
- ==🟢GREEN== — fired when an op decreases the absorbed amount (stretching back).

Implementation:

```
local borderCanvas = nil  -- one persistent canvas, reused
local function flashEdge(color, durationMs)
  if not borderCanvas then borderCanvas = hs.canvas.new(...) end
  borderCanvas[1] = { type="rectangle", action="stroke", strokeColor=color, strokeWidth=4 }
  borderCanvas:show()
  hs.timer.doAfter(durationMs/1000, function() borderCanvas:hide() end)
end
```

Edge: borrow the snap-to-edge canvas style for visual consistency. Position covers the full screen frame.

**Verification:** T1 visually — RED on shove, GREEN on stretch-back.

**Risk:** ==🟣low== — purely additive. Bug here can't break core behavior.

**Estimated:** ~50 lines.

---

### Phase 5 — Divergence detection (strict reset)

**Modifies:** the L010 module — `shove`, `stretch`, and `bumpVirtual` all check at entry.

Logic:

```
local function detectDivergence(win)
  local entry = M.sessionVirtual[win:id()]
  if not entry then return false end
  local live = win:frame()
  local expected = entry.expectedVisible
  for _, axis in ipairs({"x","y","w","h"}) do
    if math.abs(live[axis] - expected[axis]) > 5 then return true end
  end
  return false
end
```

If divergence: ==🔴wipe the session entry, set virtual := visible, log the reset==, then proceed with the operation as if it's the first shove.

**Verification:** T7 from design — absorb, then mouse-drag the window away, then press shove direction. Confirm console shows divergence-reset trace and behavior is normal step-move.

**Risk:** ==🟡medium== — false positives (Retina rounding crossing 5px in some weird scenario) would manifest as "the regrow forgot." Watch the trace during testing.

**Estimated:** ~30 lines.

---

### v0.2 stop point

==🟢User sees red borders when squeezing, green when stretching back, and external tool movement no longer corrupts state==. Still in-memory only — reload wipes.

**Test list:** T1 (visual borders), T7 (divergence). Re-verify T1–T6 still pass.

## v0.3 — Persistence

==🟢Goal==: state survives reloads. Bear notes survive close-reopen.

### Phase 6 — Disk persistence

**Creates:** ==🔵data/move-to-resize-on-single-screen.json== (created at runtime).

**Modifies:** the L010 module.

Mirror [screenmemory.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmemory.lua) patterns:

- File format: `{ "app\ntitle": { virtualFrameRel, ts } }`
- 5-second debounce after last change.
- 30-day auto-prune on init.
- Title-rename migration: when a window's title changes, copy persistent entry from old key to new key.
- `frameRel` = relative coords (x/y/w/h as fractions of `screen:frame()`).

Read on init; write on every state change (debounced).

==🔴Edge case to handle==: persistent entry whose `virtualFrameRel` extends past screen bounds (i.e., absorbed on disk). When restoring, apply via `setFrame(visibleFrame)` immediately, so the window opens already squeezed.

**Verification:**

- T5 from design: absorb, reload, stretch back, confirm regrow.
- Inspect data file to confirm format.
- T10: change resolution, confirm relative coords re-clamp correctly.

**Risk:** ==🟡medium== — file I/O bugs are easy to make. Reuse screenmemory's debounce timer pattern verbatim.

**Estimated:** ~120 lines.

---

### Phase 7 — Fresh-window heuristic + Bear opt-out

**Modifies:** the L010 module.

```
local APP_PRESERVE_ON_CLOSE = {
  ["Bear"] = true,
}

local function shouldRestoreOnNewWindow(app, persistedEntry, liveFrame, screenFrame)
  if APP_PRESERVE_ON_CLOSE[app] then return true end
  -- Default: only restore if persisted entry's virtual extends past screen
  -- AND live window is also off-screen-ish. Otherwise the user clearly opened
  -- a fresh window at default size and we shouldn't shrink it.
  local persistedExtendsOff = ... -- check virtualFrameRel exceeds [0,1] bounds
  local liveOnScreen = ... -- live window fully within screen
  if persistedExtendsOff and liveOnScreen then return false end
  return true
end
```

**Verification:**

- T6 from design: Bear close-reopen — confirm Bear note opens **already squeezed** (with the absorbed offset preserved).
- Same test for Chrome — confirm fresh window opens at default size, persistent entry is reset.

**Risk:** ==🟡medium== — the heuristic for non-Bear apps has the most opportunity to "feel wrong." Watch real usage.

**Estimated:** ~40 lines.

---

### v0.3 stop point

==🟢State survives reload. Bear close-reopen preserves squeeze. Chrome fresh tabs are not pre-squeezed.==

**Test list:** T5, T6 (with Bear), T6-variant (with Chrome). Plus a manual confidence check: use the laptop normally for half a day with the feature on, verify nothing feels haunted.

## v0.4 — Multi-screen safety

==🟢Goal==: plug-in / unplug doesn't corrupt or strand absorbed state.

### Phase 8 — Multi-screen transition handler

**Modifies:** the L010 module + minor hook in [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua).

Layout already has a screen-changed watcher; we hook into its callback:

```
function layout._onScreenCountChange(oldCount, newCount)
  if oldCount == 1 and newCount > 1 then
    ofsr.handleSingleToMulti()  -- new
  end
end
```

`handleSingleToMulti` iterates all windows with virtual state:

- For each window, compare `win:screen():id()` against the stored "home screen ID" (the built-in display).
- ==🟢If still on built-in==: keep virtual state intact. (Q5=c.)
- ==🟢If on a different display==: animated regrow via single `setFrame(virtualFrame)` (IQ4 resolved), then clear virtual state.

**Verification:** T8 from design.

**Risk:** ==🟡medium-high== — screen events fire in tricky orders during plug-in. Add a small delay (200–500ms) before iterating to let macOS settle.

**Estimated:** ~80 lines.

---

### v0.4 stop point

==🟢Feature is complete.== Multi-screen plug/unplug doesn't strand state.

**Test list:** T8, plus all prior tests on a multi-monitor setup to confirm the dispatcher gate still routes to vanilla WinWin.

## Post-implementation

### Phase 9 — README + do-done log

**Modifies:**

- ==🔵[README.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/README.md)== — add a section under the binding table noting that on single-screen, the no-modifier arrow keys behave as **shove and stretch**.
- ==🔵features/L010-move-to-resize-on-single-screen/== — add a `README.md` summary now that the feature exists; this design doc and plan stay alongside as references.
- ==🔵.claude/do-done-log/do-done-{date}-{slug}.md== — log the work for cross-project tracking.

## Risk register

| ID | Risk | Mitigation | Phase |
|----|------|------------|-------|
| R1 | Step-move re-implementation drifts from WinWin's feel (different step size, wrong rounding) | Use exact same `screen.w/30` calculation; A/B against vanilla WinWin in non-single-screen mode | 2 |
| R2 | Reset hooks miss an operation; absorbed state survives an op that should clear it | Walk every binding in stepper.lua; integration test each | 3 |
| R3 | Divergence false positives on Retina rounding | 5px tolerance is well above Retina rounding (typically <2px); watch trace | 5 |
| R4 | Persistence file corruption on crash mid-write | Reuse screenmemory's atomic write pattern (write to .tmp, rename) | 6 |
| R5 | Bear opt-out misfires (e.g., a Bear window with a generic title collides with another Bear window's persistent entry) | Acceptable per EC6; document; live with collision | 7 |
| R6 | Multi-screen transition fires before macOS finishes settling, gets wrong screen IDs | 200–500ms delay before iterating; verify with logs | 8 |
| R7 | User dislikes the squeeze-on-shove default and wants per-window toggle | Deferred to v2 ([design scope: out](design.md#scope-in--out)); revisit if real complaint emerges | n/a |
| R8 | Some app refuses to shrink past its own minimum despite our floor calculation | Detect via `setFrame` not taking effect; treat as "floor reached, stop"; log | 1 |

## Naming conventions for code

- **Module file:** `lua/move-to-resize-on-single-screen.lua`
- **Local var name:** `ofsr` ("offscreen-shrink-on-resize", short and search-friendly)
- **Public ops on the module:** `shove(win, dir)`, `stretch(win, dir)`, `reset(win)`, `bumpVirtual(win, dw, dh, dx, dy)`
- **Console trace prefix:** `[shove]` for absorbing, `[stretch]` for releasing, `[reset]` for divergence/explicit reset
- **Internal state name:** `virtualFrame` (the technical model), `absorbedLeft/absorbedRight/...` (derived per axis, not stored)
- **Visible-feedback colors:** RED `{red=0.8, green=0.2, blue=0.2}`, GREEN `{red=0.2, green=0.8, blue=0.2}` — match the existing snap-to-edge green where possible

This way, code uses precise technical names, but log output and any user-facing strings lean on **shove / stretch / squeeze**, keeping the [kinesthetic metaphor](design.md#kinesthetic-metaphor-shove-and-stretch-back) reachable for the user when they read trace output.
