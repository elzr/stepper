# [L006/screenmaps](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/) — a digital twin of the desk

> Each display config's last layout: a map of its displays at their real sizes, flat or in 3D with every window a layer, the windows by the day they were opened and last used, and a list laid out as the displays stand. ==🟢Open it on the go to see where every window was on the desk==; at the desk it's a live twin that brings a window forward when you click it.

## Contents

- [What it does](#what-it-does)
- [The views](#the-views)
- [Where the data comes from](#where-the-data-comes-from)
- [Key files](#key-files)
- [Next](#next)

## What it does

==🟢[The page](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/) shows one display config at a time==, switched at the top right: **quad** (the built-in, two 32″ LGs and two 37″ Samsungs), **single** (the built-in and one external), **dual**, **native** (the laptop alone), each listed once it has a layout. The green dot marks the config in use. ==🔵It opens on the config in use, unless that's the laptop alone==: on the go, it opens on the desk layout you last left. A config picked by hand stays picked until the page is reloaded.

- ==🟢Every save that changes something updates it== ([L006](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/)'s autosave, every minute, and 3 s after stepper moves a window to another display), and ==🔵the open page follows within 3 seconds== while it's in view. The header says "unchanged since 19:38" for the config in use, "last here Oct 7, 20:25" for the others.
- ==🟣It's a backup you can read, not one that restores==: restoring stays with L006's hotkeys and its automatic restores.
- It follows the [F030 tablogs](https://reading.internal/features/F030-tablogs/subfeatures/Chrome-tablogs/)' look: the same panel switch, day rows, chips, popup and violet front window, so the two maps read as one family.

## The views

==🟢The panel holds *Map* or *Days*== (`m`, `d`), as the tablogs' panel holds *Windows* or *Days*; ==🟢the list is always below it==.

==🟢*Map*== draws each display ==🔵at its real size==, from its EDID's millimetres: the 37″ Samsungs stand taller than the 32″ LGs are wide, though all four are 4K. The displays sit as macOS arranges them, pushed against the ones they touch so the bigger panels neither overlap nor leave gaps, and each label gives the size (`←Left 37″ · 5`). Each window is where it was, back to front, clipped to its display the way macOS shows it, with its app's icon and title (Chrome's " - Google Chrome - Eli…" tail trimmed), a faded icon in the middle of the big ones, and a tint per app.

- ==🟢*Flat | 3D*== (`3` switches): ==🔵3D tilts the plane to an isometric angle and lifts each window one layer above the one behind it==, from the front-to-back order the saves record, so a stack of maximized windows that hides itself on a flat map shows every layer. The names stand upright in a column beside the stacks, front to back, each with a hairline to its window's corner; with several displays the column gets a heading per display, and a name's hairline shows while it's hovered. ==🟢3D is the default on native==, the laptop alone, where most windows are maximized; flat elsewhere. The choice is kept per config.
- ==🔵The front window has tablogs' violet outline==; each display's top window casts a deeper shadow.
- ==🟢Minimized windows come after a rule== under the displays, as the tablogs' minimized Chrome windows do.
- ==🟢Hovering a window opens its popup==: the whole title, its app, size and display, when it was opened, moved and last used.
- ==🟢Clicking a window brings it forward== on the Mac, through `hammerspoon://screenmaps?focus=<window id>` (Chrome asks once whether to open Hammerspoon), out of the Dock if it's minimized. Only for the config in use, and not on an iPad.

==🟢*Days*== puts the windows by day twice, side by side: ==🔵*Opened*==, by the day each was first saved, and ==🔵*Last used*==, by the day it was last brought to the front, moved or minimized. Each app shows once per day with how many of its windows, most first, as the tablogs' sites do; hovering lists them. ==🟢Clicking an app or a day picks out its windows== in the list below and on the map (a banner names the pick; `Esc` clears it).

- ==🔵The windows open before screenmaps began say so== ("Fri Oct 9, already open"): macOS keeps no window's creation time, so *Opened* starts with the first save. From then on every new window gets its day.
- "Last used" is what a save can see: a window that came above the one in front at the last save, moved, appeared, went to the Dock or came back from it. A window used and left between two saves (at most a minute apart while anything changes) can be missed.

==🟢The list== is a bulleted list per display, ==🔵laid out as the displays stand==: the left display's column, the center column (Top, then Middle, then Bottom Center), the right display's column, and the minimized windows after a rule. Each window shows its icon, title and app, front to back; the front window's bullet is violet, and titles link the same way the map does.

## Where the data comes from

==🔵[lua/screenmaps.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmaps.lua) writes it==, handed each save that changed something by [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua)'s `fileSnapshot`, from what [layoutsnap.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layoutsnap.swift) read off the main thread ([changelog](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-10-09-layout-saves-off-the-main-thread.md)): the on-screen windows, every regular app's minimized ones, and each display's size in millimetres (`CGDisplayScreenSize`). ==🟢A save that writes costs about 11 ms of Hammerspoon's main thread==, and one that changes nothing writes nothing here. The running apps are read only at each config change: walking all ~190 processes takes ~40 ms.

| File (in [data/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data), untracked) | Holds |
|---|---|
| `screenmap-<config>.json` | ==🟢One per config, so each keeps its last layout while you're elsewhere==: every display (position name, monitor, size in mm, full and visible frame, rotation), the windows front to back and the minimized ones (window id, app, bundle ID, title, display, frame, and when each was first saved, last moved, last used), and `since`, when this config's map began |
| `screenmaps-now.json` | the config in use, when each config's screenmap and layout file were last written, and the running apps' bundle IDs by name |
| `app-icons/<bundleID>.png` | the icons, shared with [bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua) and [keymapwatch.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/keymapwatch.lua); missing ones are saved as apps show up |

- ==🔵A config not used since screenmaps began== is rebuilt by the page from its `window-layout-<n>.json`, with a note saying so: only the displays that held a window, at their point sizes, no window ids or times, and icons borrowed from the apps the newer maps and the running apps name. Its first use writes a real screenmap.
- ==🔵Times are per window id==, so a retitled window keeps them; a frame within 2 px of the last one hasn't moved.
- ==🔴While the screen is locked, macOS gives no windows to anyone== (Hammerspoon's own `hs.window.orderedWindows()` included), and background apps don't answer at all: the helper reports them after its 1 s per call. The save skips as it always has, and the first one after the unlock checks for drift.
- The page fetches its JSON with `?raw=1`, as the tablogs do: Caddy's [F022](https://fleet.internal/features/F022-project-files-open-richly-in-browser/) viewers answer a bare `.json` URL with their viewer page. ==🔵`stepper.internal` serves the whole stepper folder==, so the page needs no Caddy change, and it's reachable from the iPad like every `.internal` site ([F019](https://fleet.internal/features/F019-same-internal-urls-on-all-devices/)).
- ==🟣Checking on it==: `hs -c 'return layout.saveStats()'` for the saves, `hs -c 'return hs.inspect(_G._stepper.screenmaps.lastFocus)'` for the last click.

## Key files

| File | Role |
|---|---|
| [index.html](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/index.html), [screenmaps.js](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/screenmaps.js), [screenmaps.css](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/screenmaps.css) | ==🟢The page==: loads the data, picks the config, lays out the displays by size (`physicalRects`) and the list by column (`displayColumns`), draws *Map* flat or in 3D (CSS 3D transforms; `fitInStage` and `placeNames` measure the tilted plane to place it and the names), *Days* and the list, polls while in view |
| [lua/screenmaps.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmaps.lua) | Writes the data with each changed save (the times: `record`), saves the icons, handles `hammerspoon://screenmaps` |
| [lua/layoutsnap.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layoutsnap.swift) | Reads the windows, the minimized ones and the displays' sizes, in its own process |
| [lua/layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) | Hands it each changed save (`fileSnapshot`) and each config change (`setCurrent`) |

## Next

Ideas not built yet:

- **Savepoints**: keep a dated copy of a config's map when asked, as the tablogs do, to compare a desk across days.
- **Hidden apps' windows**, after the minimized ones; the helper skips them now.
- **A start page icon** on [elzr.internal/start](https://elzr.internal/start/), beside the tablogs' Chrome icon.
