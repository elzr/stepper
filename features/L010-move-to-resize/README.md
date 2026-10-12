# L010 — move-to-resize

> Push a window past a screen edge and the off-screen overflow becomes a shrink instead of disappearing. Move back is a normal slide. Pure mechanical absorb, no memory.

## Contents

- [What it does](#what-it-does)
- [When it fires](#when-it-fires)
- [The shove math](#the-shove-math)
- [Per-app floor](#per-app-floor)
- [Visual feedback](#visual-feedback)
- [Key files](#key-files)
- [Verifying it works](#verifying-it-works)
- [Original vision](#original-vision)

## What it does

==🟣fn + arrow== (no other modifier) is normally a step-move. On layouts where there's no room to spare, this module **intercepts** the step-move:

- Window flush against an edge, you press the same direction → the off-screen overflow is absorbed: the visible frame shrinks by that amount, the flush edge stays put.
- Repeat → keeps squeezing until the [per-app floor](#per-app-floor).
- Press the opposite direction → normal slide. The window stays at its squeezed size; nothing stretches back.

The result is a one-gesture way to express ==🟢"put this window on the left half"==: shove it left, it squeezes against the left edge until it fits where you want.

==🔵Anti-feature on purpose==: movement never hides the window. To hide, you minimize. The floor guarantees the window stays usably large no matter how many times you shove.

## When it fires

The dispatcher in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) picks between shove and vanilla `spoon.WinWin:stepMove` based on the current display config:

| Config | Detection | fn+arrow behavior |
|--------|-----------|-------------------|
| ==🟢single== | 1 screen | shove |
| ==🟢sidecar== | any screen named `Sidecar*` | shove (per-screen) |
| ==🟢dual== | 2 screens, none Sidecar | shove (per-screen) |
| ==🔵multi== | 3+ screens | vanilla WinWin stepMove (can cross screens) |

==🟣The rule:== if the user's layout already has lots of monitor real estate (3+ screens), let step-move slide windows across screens like normal. If they're working on a constrained layout (laptop alone, laptop + iPad, laptop + one external), squeeze instead of slide.

Per-screen behavior falls out of `win:screen()` — each window is shoved relative to the screen it's currently on, so a window on the external monitor and a window on the laptop each absorb against their own edges.

## The shove math

For each press, the module reads `win:frame()` live (no stored virtual frame), computes where the window *would* go if the screen were infinite, then clamps to screen bounds:

```
virtual.x = frame.x + dx       -- dx = ±screen.w / WinWin.gridparts (default 30)
virtual.y = frame.y + dy
visible   = virtual ∩ screen   -- shrinks on the side that went off-screen
```

If the clamp would push width or height below the floor, the absorbed edge stays pinned and the opposite edge stops moving. ==🟢Partial-step-then-stop==: a press that would cross the floor moves the window exactly to the floor and refuses further presses on that axis.

==🟣No memory==: the next press re-reads the live frame. This is why moving back is a slide (the window keeps its squeezed size) and why external tools (BTT, mouse drag, app self-resize) can't corrupt internal state.

## Per-app floor

`min(visibleW, visibleH)` is bounded below by:

```
floorW = max(200, minShrinkSize[appName].w or 0)
floorH = max(200, minShrinkSize[appName].h or 0)
```

- ==🔵Project floor==: 200×200 catches apps without an explicit minimum.
- ==🔵App-specific overrides== from [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua):`minShrinkSize` — currently only `kitty: 500×200` (kitty refuses to render shells below this; smaller frames just look broken).

The same `minShrinkSize` table also clamps the shift+arrow resize ([stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua):`clampSizeToFloor`) so the two paths can never disagree.

## Visual feedback

When a press squeezes (i.e., the visible frame got narrower or shorter), a ==🟢thick red edge== flashes on the screen edge that absorbed the overflow. Reuses the same `flashEdgeHighlight` canvas as snap-to-edge but with a red color override (`SQUEEZE_RED`).

No flash on pure slides (when the window hadn't touched the edge yet) — that keeps the visual quiet and reserves the color for the "something interesting happened" case.

There's also a console trace on every squeeze:

```
[shove] win="Bear:Note Title" dir=left vis=720x900 (squeeze)
```

Pure slides log nothing (silenced as part of the v0.4 paring-down).

## Key files

| File | Role |
|------|------|
| ==🔵[lua/move-to-resize.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/move-to-resize.lua)== | The module — pure helpers, `shove`, init, self-test (~175 lines) |
| ==🔵[lua/stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)== | `currentDisplayConfig`, `dispatchStepMove`, `ofsr.init` wiring, the `minShrinkSize` table |
| ==🔵[original-vision/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize/original-vision)== | Historical v0.1–v0.3.5 design with persisted virtual frame + stretch-back — preserved as context for what was tried and pared down |

==🔵Sibling feature:== [F043/L003-Bear-restore-on-reopen](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F043-Bear-hands/subfeatures/L003-Bear-restore-on-reopen) was originally scoped as the *dual* of L010 (visible-past vs hypothetical-future per-note geometry). That motivation survives even though L010 no longer persists anything.

## Verifying it works

After a reload, watch the console for the init line:

```bash
~/bin/hs-reload.sh
~/bin/hs-console.sh 5
# expect: [ofsr] initialized; floor=200px, flashEdge=on
```

Run the synthetic-frame self-test (no window touched):

```bash
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'return hs.inspect(_G.ofsr.selfTest())'
# expect: { pass = 17, fail = 0 }
```

Manual smoke test — on any of the [active configs](#when-it-fires):

1. Open a window, push it flush against an edge (fn+ctrl+left snaps fast).
2. Press fn+arrow toward the same edge again. ==🟢Window squeezes==; ==🔴red edge flash==.
3. Repeat until you hit the floor — the press starts being ignored.
4. Press the opposite direction — ==🟢normal slide==; window keeps its squeezed size.

If the config is "multi" (3+ screens), step-two will instead slide the window toward the neighbor screen, which is the intended escape hatch.

## Original vision

The [original-vision/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize/original-vision) folder holds the v0.1–v0.3.5 design:

- ==🔵[design.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize/original-vision/design.md)== — the shove-AND-stretch model with virtual frames, divergence detection, Bear preserve-on-close, multi-screen transitions. Includes a "v0.4 banner" flagging which sections still apply.
- ==🔵[plan.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize/original-vision/plan.md)== — the four-version phased build (v0.1–v0.4) we followed before paring back.
- ==🔵[where-were-we.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize/original-vision/where-were-we.md)== — the v0.4 paring-down summary.

==🟣They're historical, not specs==. The current code is much simpler than what they describe. If we ever want to revive stretch-back, the full implementation is preserved at git commit `7939d28`.
