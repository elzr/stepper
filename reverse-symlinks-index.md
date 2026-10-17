# Reverse symlinks

==🔵Files that live here and are symlinked back to where macOS and Claude Code look for them==, per fleet's [F033](https://fleet.internal/features/F033-tracking-changes-in-external-files/) (canonical copy + reverse symlink). Edit the copy here; the external path follows. ==🔴Renaming or moving this folder breaks every link below silently== ([F015](https://fleet.internal/features/F015-good-symlinks/)).

| File | Symlinked from | Purpose |
|------|----------------|---------|
| [hammerspoon-init.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/hammerspoon-init.lua) | `~/.hammerspoon/init.lua` | Hammerspoon's entry point: turns on hs.ipc, then loads stepper and the modules of fleet, reading and products, each in a `pcall` |
| [Spoons/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/Spoons) | `~/.hammerspoon/Spoons` (the whole folder) | `WinWin.spoon`, Hammerspoon's official spoon (MIT, unchanged since 2021), which stepper.lua loads first |
| [bin/hs](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/bin/hs) | `~/bin/hs` | Hammerspoon's CLI with a `/dev/null` stdin for `-c`, so a Claude Code call can't hang on a socket stdin (2026-10-17) |
| [bin/hs-console.sh](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/bin/hs-console.sh) | `~/bin/hs-console.sh` | The last N lines of Hammerspoon's console |
| [bin/hs-reload.sh](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/bin/hs-reload.sh) | `~/bin/hs-reload.sh` | Reloads Hammerspoon and waits for `hsLoaded`; ==🟢the first aid when typing dies and the mouse works== |

Moved in on 2026-10-17; until then they lived only at their external paths, out of git (`hs-reload.sh` since April). ==🔴`~/.hammerspoon/rcmd.lua` stays out on purpose==: the rcmd app writes it, with the token that guards its `hammerspoon://` calls, and this repo is public. A symlink would also be replaced the next time rcmd rewrites the file. The mini's init.lua is fleet's [F045 mini-hammerspoon-init.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F045-mac-mini-server/mini-hammerspoon-init.lua).
