# Fix: fn+shift resize jumping to adjacent screen

**Date**: 2026-04-04
**Symptom**: fn+shift+up at near-full height would move the window to the screen above instead of stopping or shrinking. Very disorienting — the window would suddenly disappear to the top display.

## Root cause

`smartStepResize("up")` has a special "grow upward" branch that fires when the window's bottom is pinned to the screen edge (`bottomOnly`). But once the window has grown to touch *both* top and bottom edges, `bottomOnly` becomes false (it requires `not atTop`). The function falls through to WinWin's generic `stepResize("up")`, which extends the frame above the screen boundary. macOS interprets the out-of-bounds y coordinate as a request to move the window to the adjacent screen.

Same bug existed for `smartStepResize("left")` at max width — would fall through and potentially jump to the left screen.

This is a Retina subpixel rounding interaction: the grow-upward branch extends the top edge by one grid step, but Retina rounding can place the top edge exactly at or slightly past the screen origin, causing the `atTop` snap threshold (5px) to trigger one step earlier than expected.

## Fix

**1. Handle max-height/width in smartStepResize** — When both opposite edges are touched:
- `up`: shrink from bottom, keep top pinned (mirrors how `down` at max height shrinks from top)
- `left`: shrink from right, keep left pinned (mirrors `right` at max width)

**2. guardScreen wrapper** — Safety net around all `shift` and `ctrl+shift` bindings. Captures the window's screen and frame before the operation. If the window ends up on a different screen afterward, instantly reverts the frame and logs `[stepper] screen-guard: blocked cross-screen move`. This catches any future edge cases we haven't anticipated.

## Files changed

- `lua/stepper.lua`: Added `guardScreen()` function, added max-height/width branches in `smartStepResize`, wrapped shift and ctrl+shift operation bindings with `guardScreen`.
