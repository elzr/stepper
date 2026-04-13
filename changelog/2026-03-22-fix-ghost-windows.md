# Fix Ghost Windows in Layout Save/Restore

## Context

After unplugging displays for hours and replugging, three anomalies occurred during auto-restore:
1. **Minimized Chrome window** ("📘 Diccionario") got unminimized — `allWindows()` in restore included it as a candidate, and `setFrame()`/`focus()` implicitly unminimized it
2. **Hidden Figma** (hidden by RCMD) became visible — same mechanism, `focus()` unhid it
3. **Bear window** ("_event Boda Lu") shrank to 300x250 — a ghost Bear entry (empty title, 53x48) was index-fallback-matched to it; Bear enforced its minimum size

Console log proof (line 731): `restore-bear: : saved@bottom → screen:Built-in Retina Display (win-match:index-fallback, scr-match:position) 53x48`

Root cause: two ghost entries in the save (Bear tooltip 53x48, Chrome find bar 403x84) + `allWindows()` exposing minimized/hidden windows as Tier 3 fodder.

## What are ghost windows?

`hs.window.orderedWindows()` returns not just real app windows, but also transient UI elements that macOS exposes through the accessibility API as "windows." Apps create small utility windows for things like popup menus, tooltips, find bars, and drag previews. These are supposed to be filtered by the `AXStandardWindow` subrole, but apps don't always report them correctly, so they slip through.

Two ghost windows were captured in the manual save:
- **Bear tooltip** (53x48, empty title) — likely a status popover or drag preview that Bear had open at save time
- **Chrome find bar** (403x84, title `"Find in page\n    Untitled"`) — the Cmd+F bar, which Chrome implements as a separate accessibility window

These got saved as if they were real windows with real frames, then during restore their tiny frames got applied to unrelated windows via index-fallback matching.

## Fix 1: Filter ghost windows from save

Added `isGhostWindow()` helper that filters out windows that are non-standard (`isStandard()`), smaller than 100x100, or have newlines in their title. Applied in `M.save()` with logging.

## Fix 2: Filter minimized/hidden windows from restore candidates

Replaced `hs.window.allWindows()` with `hs.window.orderedWindows()` in `restoreFromJSON()`, `retryMisses()`, and `detectMacOSPlacements()`. This matches what `save()` uses, so minimized/hidden windows can't be unminimized/unhidden during restore.

## Fix 3: Size guard on Tier 3 index-fallback

Added a minimum size check (100x100) to the Tier 3 index-fallback matching in `restoreFromJSON()`. If a saved entry's frame is too small, it's skipped with a log entry. Defense-in-depth for old save files created before Fix 1.
