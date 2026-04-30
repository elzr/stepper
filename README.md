# Hammerspoon Stepper

==🟣Non-tiling window manager built around graceful, incremental moves.==

## Contents

- [Philosophy](#philosophy)
- [Key bindings](#key-bindings)
- [Window operations](#window-operations)
- [Bear Note HUD](#bear-note-hud)
- [Mouse move](#mouse-move)
- [Further reading](#further-reading)

---

## Philosophy

==🔵Interactive steps, not preset sizes.== You build window arrangements through small, reversible increments — no snapping to halves, thirds, or memorized layouts. The result feels more like sculpting than snapping.

- **Piecemeal**: each keypress makes a small change. Hold to repeat.
- **Reversible**: every action undoes with the opposite action.
- **Predictable**: same key, same behavior, regardless of window position.
- **Overlapping-friendly**: windows overlap naturally. No forced tiling grid.

See [docs/design.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/design.md) for the full design rationale.

---

## Key bindings

All window bindings use ==🔵fn + modifier + arrow keys== (which Hammerspoon sees as Home/End/PageUp/PageDown — see [dev guide](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/dev-guide.md#fn-key-workaround) for why).

| Modifier | Action |
|---|---|
| *(none)* | ==🟢Step move== |
| **shift** | ==🟢Step resize== (bottom-right corner) |
| **ctrl** | Snap to screen edge (repeat undoes) |
| **ctrl+shift** | Resize to screen edge (repeat undoes) |
| **option** | Shrink/grow toggle |
| **shift+option** | Maximize / center / half-third cycle |
| **cmd** | Focus nearest window (same screen) |
| **option+cmd** | Focus nearest window (adjacent screen) |
| **ctrl+option** | Move window to specific display (no fn) |

==🔵Full visual reference with ASCII diagrams:== [docs/keycombo-map.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/keycombo-map.md)

---

## Window operations

### Step resize (fn + shift + arrows)

==🔵Resize from the bottom-right corner.== Left/up shrink; right/down grow. Top-left stays fixed. ==🟢Wraparound:== when growing hits a screen edge, continued presses shrink from the opposite side.

### Snap to edge (fn + ctrl + arrows)

Move window to touch the specified screen edge. ==🟢Press again when already at that edge to restore.==

### Resize to edge (fn + ctrl + shift + arrows)

Expand from current position to the specified edge. ==🟢Press again to restore.==

### Shrink/grow (fn + option + arrows)

Left/up toggle shrink to minimum size. Right/down restore or grow to screen edge. See [keycombo-map](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/keycombo-map.md#shrinkgrow-detail--↔↕) for the full matrix.

### Half/third cycle (fn + shift + option + left/right)

Cycle: ==🔵half → third → mid-third → two-thirds → restore.== Full-height, edge-aligned.

### Maximize / center (fn + shift + option + up/down)

Up toggles maximize. Down cycles: ==🔵center vertically → center horizontally → restore.==

### Focus (fn + cmd + arrows)

Focus the nearest window in that direction. ==🟢Wraps around to cycle all windows.== Skips occluded windows. Uses shadow-constrained projection to prefer windows directly above/below/beside.

### Cross-screen focus (fn + option + cmd + arrows)

Jump to adjacent screen, focusing the window closest to where you came from.

### Move to display (ctrl+option + arrows/return)

==🟣Direct arrows, no fn.== Move the focused window to a specific display by position (left/right/top/bottom/center). ==🟢Per-screen position memory==: each window remembers its size and position on every screen it visits. Repeat same combo within 1 hour to undo. See [L006](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens) for the layout system.

==🔵Sidecar mode== (iPad as extended display via macOS Sidecar): all 5 keys collapse to ==🟣"toggle to other screen"== — direction is ignored because the iPad's spatial position is fluid. Detected automatically by the screen named `Sidecar Display (AirPlay)`. In this mode, [L010](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize-on-single-screen) shove also applies on each screen — ==🟢fn+arrow shoves into edges instead of jumping to the other display==. ==🟣Pure mechanical absorb==: pushing past an edge squeezes the visible frame ([move-to-resize-on-single-screen.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/move-to-resize-on-single-screen.lua)); subsequent move-back is a normal slide, not a stretch-back.

### Layout save/restore

==🔵Automatic== save and restore of window positions across multi-display setups, handling sleep, screen lock, and display reconnection.

- **Manual save**: ctrl+option+delete — pinned, survives autosave overwrites
- **Manual restore**: ctrl+option+shift+delete — restores pinned save, falls back to autosave

---

## Bear Note HUD

==🟣Open Bear notes like a HUD== — a keyboard shortcut opens a specific note right where you left off, with caret and scroll position preserved. Configured in [bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc), implemented in [bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua).

### Note hotkeys (hyperkey + letter)

Each hotkey ==🔵toggles through three states:== open → raise/focus → minimize (macOS auto-focuses previous window).

| Key | Note |
|---|---|
| N | `_mem NOW` |
| R | `_app rcmd` |
| D | Weekly days |
| W | Weekly work |
| T | Weekly thoughts |
| S | `_topsight 2026` |
| M | `_money 2026` |
| I | `_index 2026` |

==🟢Weekly notes== (D/W/T) use template variables auto-updated every Monday by [L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts). **Right-cmd** opens previous week, **right-option** opens next week.

### Summon to cursor (right-shift + hyperkey + letter)

==🔵Teleport the note window to your mouse cursor.== Press again to return it and minimize.

### Live window hotkeys (hyper+X/Q/A/Z)

==🟢Four independently assignable quick-access slots== for any window. Set with right-option + hyper+letter (yellow flash confirms). Toggle with hyper+letter, summon with right-shift. Persists across reloads in [live-toggle-hotkeys.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/live-toggle-hotkeys.json).

### URL hotkeys (hyper+letter → URL)

The `urls` array in [bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc) binds hyperkey shortcuts to arbitrary URLs (Raycast deep links, web pages, etc.).

### Position tracking

Caret via `AXSelectedTextRange`, scroll via `AXScrollBar`, persisted to [bear-hud-positions.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-hud-positions.json). Auto-saves every 60s while Bear is frontmost.

---

## Mouse move

==🔵Hold fn + move mouse== to reposition the window under the cursor. Hold ==🔵fn + shift + move== to resize — the 3x3 grab grid determines which corner/edge moves. See [keycombo-map](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/keycombo-map.md#mouse-move) for the grid diagram. Implemented in [mousemove.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/mousemove.lua).

---

## Further reading

| Doc | What's in it |
|---|---|
| [Key combo map](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/keycombo-map.md) | ==🔵Full visual reference== with ASCII diagrams and modifier tables |
| [Dev guide](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/dev-guide.md) | ==🔴Dependencies, Lua GC gotchas, Retina rounding, testing== |
| [Design principles](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/design.md) | Philosophy and inspiration |
| [Unassigned operations](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/unassigned-operations.md) | Implemented but unbound: compact mode, native fullscreen, focus highlight |
| [Changelog](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog) | Bug fixes and feature history |
