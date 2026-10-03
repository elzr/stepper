# Claude Notes for Hammerspoon Stepper

## Project Overview

This is a Hammerspoon window management config that provides keyboard-driven window control using fn + modifier + arrow key combinations. It extends the WinWin spoon with smart resize behavior, edge snapping, cross-screen focus, and mouse move support.

## Project Structure

```
stepper/
├── lua/
│   ├── stepper.lua       # Main entry point, key bindings, core window operations
│   ├── focus.lua         # Focus navigation, occlusion detection, visual highlights
│   ├── mousemove.lua     # fn+mouse move/resize windows
│   ├── screenswitch.lua  # Move window to specific display by position
│   ├── screenmemory.lua  # Per-screen window position memory (session + persistent)
│   ├── layout.lua        # Window layout save/restore per display config; drives F010 + the guard
│   ├── displayguard.lua  # Puts the Samsung pair back in portrait after a hub re-enumeration
│   └── bear-hud.lua      # Bear note HUD with caret/scroll persistence
├── data/
│   ├── bear-notes.jsonc   # Note hotkey configuration
│   ├── display-guard.json # Per-config target rotation/mode/origin per monitor text serial
│   └── bear-hud-positions.json  # Runtime caret/scroll positions (not tracked)
├── docs/                 # Architecture notes and decision records
├── CLAUDE.md             # This file
└── README.md             # User-facing documentation
```

Modules use the standard Lua pattern: return a table of public functions, loaded via `dofile()`.

## Loading from Hammerspoon

The config lives in this Dropbox project folder and is loaded by `~/.hammerspoon/init.lua` via:
```lua
require("hs.ipc")  -- Enable CLI control
dofile("/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua")
```

## Reloading Hammerspoon from CLI

IPC must be enabled (`require("hs.ipc")` in init.lua). Use the reload script:

```bash
~/bin/hs-reload.sh
```

The script backgrounds the reload command (to avoid hanging), waits for restart, and verifies completion.

## Checking the Hammerspoon Console

Never ask the user to check the Hammerspoon console — do it yourself using the helper script:

```bash
~/bin/hs-console.sh        # last 30 lines
~/bin/hs-console.sh 10     # last 10 lines
~/bin/hs-console.sh 0      # all output
```

This reads `hs.console.getConsole()` via IPC — the actual console output with timestamps, hotkey bindings, errors, and `print()` messages.

Note: `log show --predicate 'process == "Hammerspoon"'` does NOT capture Hammerspoon's console output. Hammerspoon prints to its own console, not the macOS system log. Always use `hs-console.sh`.

## fn Key Workaround

Hammerspoon cannot bind to `fn` directly. Instead, bind to the key that fn transforms the arrow keys into:

| Physical Keys | Hammerspoon Key |
|--------------|-----------------|
| fn + Left Arrow | `home` |
| fn + Right Arrow | `end` |
| fn + Up Arrow | `pageup` |
| fn + Down Arrow | `pagedown` |
| fn + Delete | `forwarddelete` |

Example:
```lua
-- This responds to fn + cmd + Delete
hs.hotkey.bind({"cmd"}, "forwarddelete", function()
  -- ...
end)
```

## Key Bindings Pattern

The project uses a consistent modifier escalation pattern:
- No extra modifier: move window
- shift: resize
- ctrl: snap to edge
- ctrl+shift: resize to edge
- option: shrink/unshrink
- shift+option: center/maximize/half-third toggles
- cmd: focus window on same screen
- option+cmd: focus window on adjacent screen

## Documentation

**Important**: When adding or changing key bindings or user-facing behavior, always update README.md to reflect the changes. The README serves as the user-facing documentation for all operations.
