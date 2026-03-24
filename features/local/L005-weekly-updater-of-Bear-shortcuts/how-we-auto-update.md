# How We Auto-Update Bear Week Variables

## Decision

We schedule the weekly update via `hs.timer.doAt` inside `stepper.lua`, which calls `update-bear-weeks.py` through `hs.task`. The script runs on every Hammerspoon load and daily at 7am as a safety net. It's idempotent — extra runs are harmless.

## Why not launchd?

The original implementation used a launchd plist (`~/Library/LaunchAgents/com.stepper.update-bear-weeks.plist`) to run the Python script every Monday at 7am. It failed with:

```
Operation not permitted
```

### Root cause: macOS TCC and CloudStorage

`~/Library/CloudStorage/` is protected by **`kTCCServiceFileProviderDomain`** — a dedicated TCC (Transparency, Consent, and Control) service for Apple's File Provider framework. When Apple forced Dropbox/Google Drive/OneDrive off kernel extensions onto the File Provider framework, all sync roots moved to `~/Library/CloudStorage/`. Files there can be virtual placeholders that trigger downloads on access, so Apple gates them with their own TCC category — separate from Desktop/Documents/Downloads protections.

TCC uses an **attribution chain** to decide who's "responsible" for a file access:

- **Terminal**: Terminal.app has Full Disk Access, so everything spawned from Terminal inherits it. That's why `python3 update-bear-weeks.py` works fine from the command line.
- **launchd agents**: There is no responsible GUI app in the chain. Shell scripts have no bundle ID, no code signature, and can't receive TCC grants. It doesn't matter which interpreter runs the script (`/bin/bash`, `/usr/bin/python3`) — the access is denied because there's no app to attribute it to.

### Symlinks don't help

TCC resolves symlinks and checks the **real path**. A symlink at `~/.config/bear-notes.jsonc` pointing into CloudStorage would still be blocked. Apple explicitly patched this class of bypass (CVE-2024-44131 in macOS Sequoia).

### Folders that DO work for launchd

Anything not on Apple's hard-coded protected list: `~/.config/`, `~/bin/`, `~/Library/Application Support/`, `/tmp/`, etc. The restricted list is: Desktop, Documents, Downloads, CloudStorage, removable/network volumes, and app-specific data (Mail, Messages, Safari).

### Workarounds we considered and rejected

| Approach | How it works | Why we rejected it |
|----------|-------------|-------------------|
| **Automator app wrapper** | Create an .app that runs the script, grant it Full Disk Access | Hidden dependency — new Mac setup requires manual FDA grant, macOS updates can reset it |
| **Compiled Mach-O wrapper** | Tiny C binary that `execv()`s the script, granted FDA | Same manual grant fragility |
| **Move files out of CloudStorage** | Put bear-notes.jsonc in ~/.config/ | Breaks project cohesion — the file belongs with the Hammerspoon config in Dropbox |
| **Symlink from non-restricted path** | Symlink ~/.config/bear-notes.jsonc → CloudStorage | TCC resolves symlinks, still blocked |

## Why Hammerspoon is the right scheduler

- Hammerspoon is the application that *uses* `bear-notes.jsonc` — having it keep its own config fresh is natural
- It already has `kTCCServiceFileProviderDomain` permission (granted through normal macOS consent)
- Zero external dependencies — no launchd plist, no FDA grants, no wrapper apps
- Self-contained in the stepper config that's already always running
- Survives macOS updates and new machine setup (just install Hammerspoon + grant accessibility)
- `hs.task` spawns the Python script as a child process, inheriting Hammerspoon's TCC grants
- Running on load + daily at 7am means missed Mondays (laptop off, travel) are caught on next boot
