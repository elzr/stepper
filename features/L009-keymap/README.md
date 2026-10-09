# L009-keymap

> ==🔴Superseded on 2026-10-09 by [F002](https://fleet.internal/features/F002-harmonious-keybindings/)'s [keymap](https://fleet.internal/features/F002-harmonious-keybindings/keymap.html)==, which grew out of this one: every ◆ hyperkey and rcmd right-⌥ key as an A–Z list that turns into a keyboard, with the live slots, the Bear note bindings, and the clashes [F002](https://fleet.internal/features/F002-harmonious-keybindings/)'s census finds across every app.

## Contents

- [What it was](#what-it-was)
- [Where each piece went](#where-each-piece-went)
- [Why it moved](#why-it-moved)

## What it was

A Hammerspoon module ([stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) loaded it from 2026-04-19) that read rcmd's plist, stepper's hotkey data and a hand-written `notes.jsonc`, and wrote `keymap.html`: a MacBook Pro keyboard with colored underlines per layer, a bindings table, and drift warnings when a note no longer matched rcmd. Pathwatchers regenerated it on every change.

## Where each piece went

| Was here | Now |
|---|---|
| `keymap.html` (keyboard + table) | [F002/keymap.html](https://fleet.internal/features/F002-harmonious-keybindings/keymap.html), drawn in the browser from the census |
| `keymap.lua` reading rcmd and stepper's data | [F002/keybinding-census.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/keybinding-census.py), which reads every other app too |
| its pathwatchers | [lua/keymapwatch.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/keymapwatch.lua), which reruns the census |
| `notes.jsonc` (mnemonics, Bear notes, drift checks) | [F002/keymap-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/keymap-notes.jsonc), reseeded from the Bear note [_app rcmd](bear://x-callback-url/open-note?id=DC12D4B5-3818-437A-9143-D5B6A783A89B) |

The code is in git history: `git log --all -- features/L009-keymap/keymap.lua`.

## Why it moved

==🔵A keymap is half of keeping shortcuts harmonious==: it shows who owns each key, and the [F002](https://fleet.internal/features/F002-harmonious-keybindings/) census shows which owners collide. Kept apart, they read the same sources twice and still missed the apps neither one read, such as Paste holding ◆C. Together, one census feeds both.
