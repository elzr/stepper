# [L006/screenmaps](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/) — a digital twin of the desk

> Each display config's last layout, drawn as a map of its displays and as bulleted lists. ==🟢Open it on the go to see where every window was on the desk==; at the desk it's a live twin that brings a window forward when you click it.

## Contents

- [What it does](#what-it-does)
- [The views](#the-views)
- [Where the data comes from](#where-the-data-comes-from)
- [Key files](#key-files)
- [Next](#next)

## What it does

==🟢[The page](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/) shows one display config at a time==, switched at the top right: quad-32 (the built-in and four externals), only-43 (the built-in and the 43″), 37-and-43, native. The green dot marks the config in use. ==🔵It opens on the config in use, unless that's the laptop alone==: on the go, it opens on the desk layout you last left. A config picked by hand stays picked until the page is reloaded.

- ==🟢Every save that changes something updates it== ([L006](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/)'s autosave, every minute, and 3 s after stepper moves a window to another display), and ==🔵the open page follows within 3 seconds== while it's in view. The header says "unchanged since 19:38" for the config in use, "last here Oct 7, 20:25" for the others.
- ==🟣It's a backup you can read, not one that restores==: restoring stays with L006's hotkeys and its automatic restores. This page is for remembering, and for seeing the whole desk at once.
- It follows the [F030 tablogs](https://reading.internal/features/F030-tablogs/subfeatures/Chrome-tablogs/)' look: the same panel, *Map | List* switch, popup and violet front window, so the two maps read as one family.

## The views

==🟢*Map*== draws each display where it sits, at true proportions (quad-32's cross of displays: the portrait Samsungs on the sides, the LGs stacked over the built-in), and each window where it was, back to front, clipped to its display the way macOS shows it.

- A window shows its app's icon and its title (Chrome's " - Google Chrome - Eli…" tail trimmed); a big one also carries its app's icon, faded, in the middle, and each app has a tint of its own.
- ==🔵The front window has tablogs' violet outline==; each display's top window casts a deeper shadow. Each display's label counts its windows.
- ==🟢Hovering a window opens its popup==: the whole title, its app, size and display, and since when it has been in place (or when it moved, and when it was first saved).
- ==🟢Clicking a window brings it forward== on the Mac, through `hammerspoon://screenmaps?focus=<window id>` (Chrome asks once whether to open Hammerspoon). Only for the config in use, and not on an iPad.

==🟢*List*== is the bulleted version: a section per display, left to right and each column top to bottom, its windows front to back with icon, title and app. The front window's bullet is violet; titles link the same way. `m` and `l` switch the views.

## Where the data comes from

==🔵[lua/screenmaps.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmaps.lua) writes it==, handed each save that changed something by [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua)'s `fileSnapshot`, from the windows [layoutsnap.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layoutsnap.swift) read off the main thread ([changelog](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-10-09-layout-saves-off-the-main-thread.md)). ==🟢A save that writes still costs about 11 ms of Hammerspoon's main thread== (10.9 ms measured, with the times seeded from the file), and one that changes nothing writes nothing here. The running apps are read only at each config change: walking all ~190 processes takes ~40 ms.

| File (in [data/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data), untracked) | Holds |
|---|---|
| `screenmap-<config>.json` | ==🟢One per config, so each keeps its last layout while you're elsewhere==: every display (position name, monitor, full and visible frame, rotation) and the windows front to back (window id, app, bundle ID, title, display, frame, when first saved, when last moved) |
| `screenmaps-now.json` | the config in use, when each config's screenmap and layout file were last written, and the running apps' bundle IDs by name |
| `app-icons/<bundleID>.png` | the icons, shared with [bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua) and [keymapwatch.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/keymapwatch.lua); missing ones are saved as apps show up |

- ==🔵A config not used since screenmaps began== (only-43, last used Oct 7) is rebuilt by the page from its `window-layout-<n>.json`, with a note saying so: only the displays that held a window, no window ids, and icons borrowed from the apps the newer maps and the running apps name. Its first use writes a real screenmap.
- ==🔵"Moved" is per window id==, so a retitled window keeps its times; a frame within 2 px of the last one hasn't moved. The times start on 2026-10-09: every window's "in place since" is at least that.
- The page fetches its JSON with `?raw=1`, as the tablogs do: Caddy's [F022](https://fleet.internal/features/F022-project-files-open-richly-in-browser/) viewers answer a bare `.json` URL with their viewer page. ==🔵`stepper.internal` serves the whole stepper folder==, so the page needs no Caddy change, and it's reachable from the iPad like every `.internal` site ([F019](https://fleet.internal/features/F019-same-internal-urls-on-all-devices/)).
- ==🟣Checking on it==: `hs -c 'return layout.saveStats()'` for the saves, `hs -c 'return hs.inspect(_G._stepper.screenmaps.lastFocus)'` for the last click.

## Key files

| File | Role |
|---|---|
| [index.html](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/index.html), [screenmaps.js](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/screenmaps.js), [screenmaps.css](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/screenmaps.css) | ==🟢The page==: loads the data, picks the config, draws *Map* and *List*, polls while in view |
| [lua/screenmaps.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmaps.lua) | Writes the data with each changed save, saves the icons, handles `hammerspoon://screenmaps` |
| [lua/layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) | Hands it each changed save (`fileSnapshot`) and each config change (`setCurrent`) |

## Next

Ideas from the first version, not built yet:

- ==🟣A time view==, like the tablogs' *Days*: the windows by when they last moved or first appeared. The times are recorded from 2026-10-09 on.
- **Savepoints**: keep a dated copy of a config's map when asked, as the tablogs do, to compare a desk across days.
- **Minimized windows and hidden apps** after a rule, as the tablogs show minimized Chrome windows; [layoutsnap.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layoutsnap.swift) reads only what's on screen now.
- **A start page icon** on [elzr.internal/start](https://elzr.internal/start/), beside the tablogs' Chrome icon.
