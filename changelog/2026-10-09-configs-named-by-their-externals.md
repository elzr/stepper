# Display configs named by their external displays

**Date**: 2026-10-09

==🔴The config names had outlived the monitors they named==: quad-32 for four 32″ LGs, after the side two became 37″ Samsungs on 2026-10-02, and only-43 and 37-and-43 for setups with 43″ TVs that are gone. [L006/screenmaps](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/) put them on a page, where they read as wrong.

**Change**: ==🟢[layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua)'s `KNOWN_CONFIGS` names them by their external displays==: **quad** (5 screens: the built-in, two 32″ LGs, two 37″ Samsungs), **dual** (3), **single** (2: the built-in and one external), **native** (1). The names show in the console's `[layout]` lines and the screenmaps page; the layout files stay named by count (`window-layout-5.json`).

- ==🔴[display-guard.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/display-guard.json) is keyed by config name==, and the guard does nothing for a config it has no targets for, so its `quad-32` key became `quad` in the same step. Checked after the reload: `[layout.guard] ok (init)` for both Samsungs.
- ==🔵The TV setups' last layouts were retired==, not deleted: `window-layout-2.json` (Oct 7) and `window-layout-3.json` (Jul 12) moved to [layout-backups/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/layout-backups) as `retired-only-43-tv-2026-10-07-c2.json` and `retired-37-and-43-tv-2026-07-12-c3.json`. Otherwise the first single session would restore its windows to an old TV's layout.
- `screenmap-quad-32.json` became `screenmap-quad.json`, keeping its windows' times.
- ==🟣The middle LG's EDID says 598 × 341 mm (27″)==, the top one's 702 × 400 mm (32″); screenmaps draws what the EDID says.
