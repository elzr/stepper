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
│   ├── layoutsnap.swift  # Reads the windows a save records, off Hammerspoon's main thread (binary untracked)
│   ├── screenmaps.lua    # Writes L006/screenmaps' data (data/screenmap-<config>.json, screenmaps-now.json) with each changed save; hammerspoon://screenmaps
│   ├── displayguard.lua  # Puts the Samsung pair back in portrait after a hub re-enumeration
│   ├── inputprobe.lua    # Context for "[stepper] lost key-up" lines: HID key state, event taps, wake times
│   ├── inputprobe.swift  # Its helper, built on first use (binary untracked)
│   ├── cmdtabwatch.lua   # Keeps the dead ⌘⇥ watcher running for the AltTab trial, and AltTab's own debug log on (fleet F040/AltTab)
│   ├── cmdtabwatch.swift # The watcher: listen-only taps, logs each ⌘⇥ that did nothing (binary untracked)
│   ├── modpairs.lua      # R⌘ + R⌥ ×2 and L⌥ + L⌘ ×2 (a same-side pair tapped twice): detection only, free since the 2026-10-15 trial
│   ├── keymapwatch.lua   # Reruns fleet F002's keybinding census when rcmd's keys or stepper's hotkey data change; feeds F002's keymap.html, and disables a BTT trigger for its Modifiers × (hammerspoon://keymap-clear)
│   └── bear-hud.lua      # Bear note HUD with caret/scroll persistence
├── data/
│   ├── bear-notes.jsonc   # Note hotkey configuration
│   ├── display-guard.json # Per-config target rotation/mode/origin per monitor text serial
│   ├── cmd-tab-watch.jsonl # The watcher's log, plus AltTab stack samples in cmd-tab-samples/ (not tracked)
│   ├── live-toggle-hotkeys.json # live ◆ slots (letters and 6–0: bear-notes.jsonc's liveKeys); fleet F002's keymap.html shows them live (caddy lets it read this file), with icons from app-icons/ (not tracked). Only bear-hud writes it: the page asks over hammerspoon://keymap?free|set|move|erase
│   ├── live-toggle-history.jsonl # a line per live slot set or freed (bear-hud appends); the keymap's ⏱ per key
│   └── bear-hud-positions.json  # Runtime caret/scroll positions (not tracked)
├── bin/                  # hs, hs-console.sh, hs-reload.sh: ~/bin symlinks here (reverse-symlinks-index.md)
├── docs/                 # Architecture notes and decision records
├── hammerspoon-init.lua  # ~/.hammerspoon/init.lua, symlinked here
├── reverse-symlinks-index.md # What's symlinked from outside the repo (fleet F033)
├── CLAUDE.md             # This file
└── README.md             # User-facing documentation
```

Modules use the standard Lua pattern: return a table of public functions, loaded via `dofile()`.

## Loading from Hammerspoon

The config lives in this Dropbox project folder and is loaded by `~/.hammerspoon/init.lua`, itself a symlink to this repo's `hammerspoon-init.lua` (edit it here), via:
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

## The keyboard runs through Hammerspoon: never block it, never probe it from `hs -c`

Stepper keeps active event taps on `keyDown` and `flagsChanged` ([modpairs.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/modpairs.lua), inputprobe). macOS hands every keystroke to those callbacks and waits for the answer, so ==🔴anything that stalls or breaks Hammerspoon's main thread stalls or kills the user's typing== while the mouse keeps working. Two ways to do that, both seen on 2026-10-17 ([case study](https://fleet.internal/features/F041-happy-hardware/subfeatures/UI-peripherals/case-studies/2026-10-17-intuos-in-android-mode-and-the-driver-that-lost-its-poster.md#the-keyboard-freeze)):

1. ==🔴An event tap or any callback installed through `hs -c`== (IPC): the chunk's `print` is the IPC connection's, and once the command has returned every call to it raises `ipc.lua:402: attempt to index a nil value`. A tap whose callback errors on every event swallowed a minute of the user's keystrokes until a reload destroyed it. Diagnostics go in a `.lua` file loaded by init.lua, with the callback wrapped in `pcall`, writing to a file; `hs -c` is for one-shot queries and `hs.reload()`.
2. ==🔴Blocking calls on the main thread==: `hs.application.open(bundle, wait)`, `hs.eventtap.keyStroke` with its default 0.2 s delay, `hs.osascript` round trips, `os.execute`, sleeps. Launch and then poll with `hs.timer.waitUntil`; pass `0` as keyStroke's delay; keep work in timers.

When a user reports dead typing with a live mouse, ==🟢`~/bin/hs-reload.sh` is the first aid==: it destroys every tap and rebuilds the config in under a second.

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
