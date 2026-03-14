# Hammerspoon Stepper

Non-tiling window manager based around graceful moves.

## Philosophy

Stepper is built around **interactive steps, not preset sizes**. Instead of snapping to halves, thirds, or other fixed layouts, you build window arrangements through small, reversible increments.

- **Piecemeal**: Each keypress makes a small change. Repeat to continue.
- **Reversible**: Every action can be undone by the opposite action.
- **No presets**: No half-screen, no thirds, no memorized layouts. Just steps.
- **Predictable**: The same key always does the same thing, regardless of window position.
- **Instant**: No animations. All operations happen immediately.

### Why Not a Tiling Manager?

Traditional tiling managers offer two extremes: rigid presets ("snap to left half") or complete tiling tyranny (every window must tile, no overlap allowed). Stepper takes a different path:

- **Iterative**: Both position and size are adjusted incrementally. Hold the key to keep going.
- **Overlapping-friendly**: Windows can overlap naturally. No forced tiling grid.
- **Organic layouts**: Your arrangement emerges from small adjustments, not preset templates.
- **Predictable**: The same key always does the same thing. No hidden modes or position-dependent behavior.

The result feels more like sculpting than snapping.

## Key Bindings

All bindings use **fn + modifier + arrow keys** (Home/End/PageUp/PageDown):

| Modifier | Action | Keys |
|----------|--------|------|
| *(none)* | Step move | fn + arrows |
| **shift** | Step resize | fn + shift + arrows |
| **ctrl** | Move to screen edge | fn + ctrl + arrows |
| **ctrl+shift** | Resize to screen edge | fn + ctrl + shift + arrows |
| **option** | Shrink/unshrink | fn + option + arrows |
| **cmd** | Focus within current screen | fn + cmd + arrows |
| **option+cmd** | Focus across screens | fn + option + cmd + arrows |
| **shift+option** | Maximize cycle | fn + shift + option + up |
| **shift+option** | Center toggle | fn + shift + option + down |
| **shift+option** | Half/third/mid-third/two-thirds cycle | fn + shift + option + left/right |

## Step Resize Behavior (fn + shift + arrows)

Resize from the bottom-right corner. The arrow keys move that corner in the indicated direction:

- **left/up**: shrink (pull the corner inward)
- **right/down**: grow (push the corner outward)

The top-left corner stays fixed. Use ctrl+arrow to re-snap to an edge after resizing.

**Wraparound**: When growing hits a screen edge, the resize wraps to shrinking from the opposite side. For example, a window at the top of the screen can be resized down until it fills the screen, then continued presses shrink it from the top while staying stuck to the bottom.

## Other Operations

### Move to Edge (fn + ctrl + arrows)
Moves the window to touch the specified screen edge without resizing.
**Reversible**: Press again when already at that edge to restore previous position.

### Resize to Edge (fn + ctrl + shift + arrows)
Expands the window to fill from its current position to the specified edge.
**Reversible**: Press again when already at that edge to restore previous size.

### Shrink/Grow (fn + option + arrows)
- **left**: Toggle shrink width to minimum (press again to restore)
- **up**: Toggle shrink height to minimum (press again to restore)
- **right**: Restore shrunk width, or grow to right edge if not shrunk (toggle)
- **down**: Restore shrunk height, or grow to bottom edge if not shrunk (toggle)

### Focus Direction (fn + cmd + arrows)
Focus the nearest window in that direction (on the same screen):
- **left/right**: based on window's left edge (x position)
- **up/down**: based on window's top edge (y position)
- Wraps around: keep pressing to cycle through all windows on the screen
- **Skips hidden windows**: Windows fully covered by other windows are excluded
- **Shadow-constrained**: Prioritizes windows that overlap with the current window's projection:
  - Up/down first looks for windows with horizontal overlap (directly above/below)
  - Left/right first looks for windows with vertical overlap (directly beside)
  - Falls back to all screen windows if no overlapping candidates exist

### Focus Across Screens (fn + option + cmd + arrows)
Jump to an adjacent screen, focusing the window closest to where you came from:
- **left**: go to left screen, focus window with rightmost edge
- **right**: go to right screen, focus window with leftmost edge
- **up**: go to upper screen, focus window with bottommost edge
- **down**: go to lower screen, focus window with topmost edge
- **Skips hidden windows**: Windows fully covered by other windows are excluded

### Move to Display (ctrl+option + arrows/return)
Move the focused window directly to a specific display:
- **ctrl+option+down**: Bottom center (MacBook built-in)
- **ctrl+option+up**: Top center
- **ctrl+option+left**: Left
- **ctrl+option+right**: Right
- **ctrl+option+return**: Middle center

These are direct arrow keys (no fn needed). The window's offset from the screen origin is preserved. If the window would extend beyond the target screen, it's clamped to stay fully visible. If too large, it shrinks to fit — the original dimensions are remembered and automatically restored when moving to a screen where they fit.

**Repeat to undo**: pressing the same combo again within 1 hour moves the window back to its original screen, position, and size. A different combo starts a new move (overwriting the undo memory for that window).

### Layout Save/Restore

Automatically saves the window layout when connected to the 5-display desk setup, and auto-restores when all 5 displays return (e.g., after sleep or reconnecting).

- **Auto-save**: Every 1 minute while at 5 displays, and on system sleep
- **Backup rings**: 10 one-minute backups (~10 min history) + 10 ten-minute backups (~100 min history) in `data/layout-backups/`
- **Display guard**: Auto-save only fires at 5 displays — sleeping with fewer screens won't overwrite the good layout
- **Screen watcher**: When displays are added/removed, a 2-second debounce waits for all screens to stabilize before acting
- **Auto-restore**: When transitioning to 5 displays, automatically restores the saved layout
- **Manual save**: **ctrl+option+delete** (fn+ctrl+alt+delete) — pinned save, never overwritten by autosave
- **Manual restore**: **ctrl+option+shift+delete** (fn+ctrl+alt+shift+delete) — restores pinned save; falls back to latest autosave if no pinned save exists

### Maximize Cycle (fn + shift + option + up)
Progressive maximize:
1. First press: maximize height (keep width and horizontal position)
2. Second press: maximize width too (true full-screen maximize)
3. Third press: restore previous size and position

### Center Toggle (fn + shift + option + down)
Progressive centering:
1. First press: center vertically
2. Second press: center horizontally
3. Third press: restore previous position

### Half/Third Cycle (fn + shift + option + left/right)
Cycle through edge-aligned layouts:
1. First press: half-width, full-height, aligned to that edge
2. Second press: third-width, full-height, aligned to that edge
3. Third press: middle third (centered, full-height)
4. Fourth press: two-thirds-width, full-height, aligned to that edge
5. Fifth press: restore previous size and position

## Unassigned (Available Functions)

The following operations are implemented but not currently bound to keys:

### Max Height
Expand window to full screen height while keeping width and horizontal position.
**Reversible**: Press again to restore previous height.

### Max Width
Expand window to full screen width while keeping height and vertical position.
**Reversible**: Press again to restore previous width.

### Compact Mode
Shrink window to a small size and dock it at the bottom of the screen.
- Works like a minimized dock: windows line up left-to-right at the screen bottom
- Each new compact window appears to the right of existing ones
- Wraps to the row above when the bottom row is full
- Press again to restore original size and position
- App-specific minimum sizes are respected (see `minShrinkSize` in config)

### Native Fullscreen
Toggle macOS native fullscreen mode (with the green button animation).

### Show Focus Highlight (fn + cmd + delete)
Flash a border around the currently focused window. Useful for locating which window has keyboard focus.

## Bear Note HUD

Open Bear notes like a HUD: a keyboard shortcut opens a specific note right where you left off, with caret and scroll position preserved.

### Note Hotkeys (hyperkey + letter)

Configured in `bear-notes.jsonc`. Each hotkey toggles through three states:

| Press | State | Action |
|-------|-------|--------|
| 1st | Not open | Opens note in Bear, restores caret/scroll position |
| 2nd | Open, not focused | Raises + focuses the note window |
| 3rd | Focused | Minimizes the window, macOS auto-focuses previous |

### Summon to Cursor (right-shift + hyperkey + letter)

Hold the **right shift** key while pressing the hyperkey combo to summon the note window to your mouse cursor. Press again (with right-shift) to return it to its original position and minimize it (macOS auto-focuses the previous window).

Summon works whether the note is open or not — if closed, it opens and summons in one step.

Default bindings (hyperkey = ctrl+alt+shift+cmd):

| Key | Note |
|-----|------|
| N | `_mem NOW` |
| R | `_app rcmd` |
| D | Weekly days |
| W | Weekly work |
| T | Weekly thoughts |
| S | `_topsight 2026` |
| I | `_index 2026` |

Weekly note titles use template variables (`weekNum`, `weekDays`) defined in `bear-notes.jsonc`.

**Past week**: Hold the **right command** key while pressing hyper+D/W/T to open the previous week's note instead. Uses `pastWeekNum`/`pastWeekDays` vars.

**Next week**: Hold the **right option** key while pressing hyper+D/W/T to open the next week's note. Uses `nextWeekNum`/`nextWeekDays` vars.

Notes without a `pastTitle`/`nextTitle` (N, R, S, I, M) are unaffected by these modifiers.

### Live Window Hotkeys (hyper+X/Q/A/Z)

Four independently assignable "quick access" hotkeys for any window — terminals, browsers, docs, or Bear notes. Each slot captures a window by app + title, so you can toggle it back instantly.

- **Set**: Focus any window, then press **right-option + hyper+{X,Q,A,Z}**. A yellow flash confirms the binding.
- **Use**: **hyper+{letter}** toggles the window (raise/minimize). **right-shift + hyper+{letter}** summons it to the cursor.
- **Bear bonus**: If the pinned window belongs to Bear, caret and scroll position are automatically saved/restored.
- **Window gone**: If the app quit or the window was closed, a console message is printed (no-op). Bear notes are re-opened automatically.
- **Persist**: Stored in `data/live-toggle-hotkeys.json`, survives Hammerspoon reloads.

### URL Hotkeys (hyper+letter → open URL)

The `urls` array in `bear-notes.jsonc` binds hyperkey shortcuts to arbitrary URLs, using the same modifier infrastructure as Bear note hotkeys.

| Key | URL |
|-----|-----|
| F | `raycast://extensions/sara/featurebase/index` (Featurebase — see topsight/F020) |

**JSONC caveat:** The comment stripper (`content:gsub("//...", "")`) was updated to skip `://` in URLs. Without this fix, `raycast://extensions/...` gets mangled — the `//` is treated as a comment, silently corrupting the JSON and preventing the binding from registering.

### URL Handler

The `hammerspoon://open-bear-note` URL handler is also available for external launchers:

```
hammerspoon://open-bear-note?title=<encoded title>
hammerspoon://open-bear-note?id=<note id>
```

### Position Tracking

- **Caret**: Read/written via `AXSelectedTextRange` on Bear's `AXTextArea`
- **Scroll**: Read/written via `AXValue` on the vertical `AXScrollBar`
- **Storage**: `bear-hud-positions.json` (persists across Hammerspoon reloads)
- **Auto-save**: Every 60s while Bear is frontmost + on Bear deactivate
- **ID support**: When opened by `id`, learns the title→id mapping so auto-save works by id

## Mouse Move

Hold **fn** and move the mouse to reposition the window under the cursor.
Useful for apps where other window managers don't work (Kitty, Bear, etc.).

Hold **fn + shift** and move to resize. The window is divided into a 3x3 grid — where you grab determines the resize behavior:

| Cursor position | Resize behavior |
|----------------|-----------------|
| Corner (e.g. top-left) | Resize from that corner; opposite corner stays fixed |
| Edge (e.g. right) | Resize that edge only; opposite edge stays fixed |
| Center | Move the window (same as fn-only) |

Releasing shift or fn stops the operation cleanly.

## Dependencies

- [WinWin Spoon](http://www.hammerspoon.org/Spoons/WinWin.html)
