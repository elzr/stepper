# L005: Weekly Updater of Bear Shortcuts

Auto-updates the week number and date-range variables in [data/bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc) every Monday, so Bear note hotkeys (Hyper+D/W/T) always open the correct weekly note.

## Contents

- [How It Works](#how-it-works)
- [Files](#files)
- [Git sees only hand edits](#git-sees-only-hand-edits)
- [Why Hammerspoon, not launchd?](#why-hammerspoon-not-launchd)
- [Manual Run](#manual-run)
- [Year Boundary](#year-boundary)

## How It Works

1. `week-data.json` — cached lookup of all 53 ISO weeks → date-range strings (from the [year-weeks spreadsheet](https://docs.google.com/spreadsheets/d/1nIMtN2w4JZs1K7h1_Y2qrT6RuQXKtgBvBBu3iIIdrDg/edit?gid=385652933))
2. `update-bear-weeks.py` — computes current ISO week, looks up current/prev/next date ranges, updates the 6 vars in `bear-notes.jsonc`, reloads Hammerspoon
3. **Scheduling**: `stepper.lua` runs the script on Hammerspoon load + daily at 7am via `hs.timer.doAt`. (Previously used a launchd plist, but launchd can't access `~/Library/CloudStorage/` paths due to macOS TCC restrictions.)

## Files

| File | Purpose |
|------|---------|
| [fetch-week-data.sh](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/fetch-week-data.sh) | One-time: fetches week data from Google Sheets via `gws` → `week-data.json` |
| [update-bear-weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/update-bear-weeks.py) | Weekly: computes week, updates JSONC vars, reloads Hammerspoon |
| [week-data.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/week-data.json) | Cached week lookup (53 entries) |
| [git-week-filter.sh](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/git-week-filter.sh) | Git clean filter that blanks week names (see below) |
| [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) (weekUpdate section) | Runs script on load + daily 7am via `hs.timer.doAt` |
| [data/bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc) | The file being updated (vars block) |

## Git sees only hand edits

The Monday roll rewrites the week names in `bear-notes.jsonc` and, through it, in [L009](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap)'s generated `keymap.html`. Those changes aren't worth tracking, but hand edits to either file are. [.gitattributes](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/.gitattributes) runs both files through `git-week-filter.sh`, which blanks week numbers to `NN` and date ranges to `DAYS` before git compares or stores them. ==🟢A roll leaves `git status` clean==, while a new note hotkey still shows up as a normal diff.

- ==🔵One-time setup per clone== (without it git just shows the weekly noise again):
  `git config filter.l005-weeks.clean features/L005-weekly-updater-of-Bear-shortcuts/git-week-filter.sh`
- ==🟣Git stores the blanked text==, so a checkout or stash of these files writes `NN`/`DAYS` into the working copy. `update-bear-weeks.py` refills them on the next Hammerspoon reload, wake or Monday.

## Why Hammerspoon, not launchd?

See [how-we-auto-update.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/how-we-auto-update.md) — launchd agents can't access `~/Library/CloudStorage/` due to macOS TCC restrictions. Hammerspoon already has the right permissions and is always running.

## Manual Run

```bash
python3 update-bear-weeks.py
```

## Year Boundary

At the start of each new year, re-run `fetch-week-data.sh` against the new year's tab in the spreadsheet to refresh `week-data.json`.
