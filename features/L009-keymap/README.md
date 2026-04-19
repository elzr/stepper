# L009-keymap

> ==🟣Auto-regenerating visual map of all my keyboard shortcuts== — rcmd, Stepper hyper, and others. Hand-edit the annotations file; everything else mirrors live config.

## Contents

- [What it does](#what-it-does)
- [Layers](#layers)
- [Source files](#source-files)
- [Regen triggers](#regen-triggers)
- [Drift warnings](#drift-warnings)
- [Related](#related)

## What it does

Generates [keymap.html](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/keymap.html) — a full MacBook Pro M1 Max keyboard diagram with thin colored underlines per layer, plus a filterable bindings table below. ==🟢Empty key tiles render too==, so unused real estate is visible at a glance.

Served by caddy at [stepper.internal/features/L009-keymap/keymap.html](https://stepper.internal/features/L009-keymap/keymap.html).

## Layers

| Layer | Modifier | Source |
|---|---|---|
| ==🟠rcmd== | right-opt + key | [rcmd plist](openfile:///Users/sara/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist) |
| ==🔵stepper-hyper== | hyper (caps lock) + key | [bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc), [hyper-actions.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/hyper-actions.jsonc), [live-toggle-hotkeys.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/live-toggle-hotkeys.json) |
| ==🟣other== | varies (BTT, system, app shortcuts) | manual entries in [notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/notes.jsonc) |

==🔵◆== marks any key bound through the hyper modifier.

## Source files

| File | Purpose |
|---|---|
| [keymap.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/keymap.lua) | Generator + pathwatchers (loaded from [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)) |
| [notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/notes.jsonc) | Editorial seed: mnemonics, notes, bearNote wikilinks, expectedApp |
| [keymap.html](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/keymap.html) | Generated artifact (tracked) |
| [keymap.css](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/keymap.css) | Static styles |
| [keymap.js](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap/keymap.js) | Click-to-filter + pill toggles |

## Regen triggers

| Event | Mechanism |
|---|---|
| HS reload (incl. weekly via [L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts)) | `M.init()` runs `M.generate()` |
| rcmd plist write (changing a binding in rcmd.app) | `hs.pathwatcher` on plist |
| Live-toggle reassign (R⌥+hyper+X/Q/A/Z) | `hs.pathwatcher` on `live-toggle-hotkeys.json` |
| Manual edit of any config or `notes.jsonc` | `hs.pathwatcher`, debounced 0.5s |

## Drift warnings

If `notes.jsonc` annotates `Q → Cursor` but rcmd no longer binds `Q` (or binds it to something else), the HTML shows ==🔴a warning banner== plus a red corner dot on the affected key. ==🟢This catches drift between mental model and reality==, e.g. when you stop using an app but the annotation lingers.

## Related

- ==🔵[L007-hyperkey-shortcuts](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L007-hyperkey-shortcuts)== — the hyperkey system this map visualizes
- [L005-weekly-updater-of-Bear-shortcuts](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts) — why HS reload covers weekly regen
