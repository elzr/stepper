# Session: 20260208-dfece8

---
*2026-02-08 20:24* <!-- 62044114 -->

## Eli:
Implement plan: Match macOS Tahoe continuous corners in border highlight

## Claude:
Now I see the issue. The junction points are at `0.63149379` (which I had as `0.66993427` — that's a control point, not a junction). Let me verify by checking the second source too.

Looking at the three bezier segments for the top-right corner more carefully:

- Segment 1: from `(1.528665*r, 0)` → to `(0.63149379*r, 0.07491139*r)` with c1=`(1.08849296*r, 0)`, c2=`(0.86840694*r, 0)`
- Segment 2: from `(0.63149379*r, 0.07491139*r)` → to `(0.07491139*r, 0.63149379*r)` with c1=`(0.37282383*r, 0.16905956*r)`, c2=`(0.16905956*r, 0.37282383*r)`
- Segment 3: from `(0.07491139*r, 0.63149379*r)` → to `(0, 1.52866498*r)` with c1=`(0, 0.86840694*r)`, c2=`(0, 1.08849296*r)`

These are in a coordinate system relative to the top-right corner, where `topRight(x, y)` means the x goes leftward and y goes downward from the corner.

So translating to absolute coords where top-right corner is at `(R, T)`:
- `topRight(x, y)` = `(R - x*r, T + y*r)`

Segment 1: from `(R - 1.528665*r, T)` → to `(R - 0.63149*r, T + 0.07491*r)`
  c1 = `(R - 1.08849*r, T)`, c2 = `(R - 0.86841*r, T)`

Segment 2: from `(R - 0.63149*r, T + 0.07491*r)` → to `(R - 0.07491*r, T + 0.63149*r)`
  c1 = `(R - 0.37282*r, T + 0.16906*r)`, c2 = `(R - 0.16906*r, T + 0.37282*r)`

Segment 3: from `(R - 0.07491*r, T + 0.63149*r)` → to `(R, T + 1.52866*r)`
  c1 = `(R, T + 0.86841*r)`, c2 = `(R, T + 1.08849*r)`

Now in hs.canvas segments, `c1` and `c2` for a coordinate are the control points for the curve **from the previous point to this point**. So for each "to" point, c1 is near the previous point and c2 is near the current point.

Let me verify my implementation against this. In my code for the top-right corner:

```lua
-- Top-right corner (3 bezier segments)
{x = R - c, y = T, c1x = R - b, c1y = T, c2x = R - d, c2y = T + hh},
```

This means: curve from previous `(R-a, T)` to `(R-c, T)` with c1=`(R-b, T)`, c2=`(R-d, T+hh)`.

But from the reference, the destination of segment 1 is `(R - 0.63149*r, T + 0.07491*r)`, not `(R - c*r, T)`. My constants `c = 0.86840689` which is a control point value, not the junction point `0.63149379`.

I have the wrong constants! Let me fix the constants and the path. The actual junction points are at `0.63149379` and `0.07491139`, not `c` and `g`.

Let me also double-check by looking at a well-known implementation.

---
*2026-02-08 20:30* <!-- 4675965a -->

## Eli:
[Image: original 7680x4320, displayed at 2000x1125. Multiply coordinates by 3.84 to map to original image.]

## Claude:
Here's a summary of the changes:

**`focus.lua`** — Added continuous corner path builder and shared border canvas API:
- `continuousCornerCoords()` builds a 17-point closed path with 12 cubic bezier segments (3 per corner) using Apple's exact constants from PaintCode's reverse-engineering
- `emphasisCoords()` generates the thick directional emphasis line, inset by `a*r` to align with where the curve starts
- `createBorderCanvas(frame, dir)` / `updateBorderCanvas(canvas, frame)` / `deleteBorderCanvas(canvas)` — shared API used by both focus flash and mouse drag
- `flashFocusHighlight` refactored to use `createBorderCanvas` internally

**`mousedrag.lua`** — Removed duplicated border drawing:
- Removed `showDragBorder`/`hideDragBorder` canvas management and local constants
- Replaced with thin wrappers calling the injected `createBorderCanvas`/`updateBorderCanvas`/`deleteBorderCanvas` functions
- `init(opts)` now accepts the border functions

**`stepper.lua`** — Wires focus border API into mousedrag:
- `mousedrag.init()` call now passes the three `focus.*BorderCanvas` functions

The key visual improvement: corners now use Apple's continuous curvature (3 bezier segments per corner) instead of circular arcs, matching macOS Tahoe window chrome. The curve starts at `1.53*r` from each corner and eases in through junction points at `0.63*r` and `0.075*r`, eliminating the abrupt curvature transition of circular arcs.
