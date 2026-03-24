# L005: Weekly Updater of Bear Shortcuts

Auto-updates the week number and date-range variables in `data/bear-notes.jsonc` every Monday, so Bear note hotkeys (Hyper+D/W/T) always open the correct weekly note.

## How It Works

1. `week-data.json` — cached lookup of all 53 ISO weeks → date-range strings (from the [year-weeks spreadsheet](https://docs.google.com/spreadsheets/d/1nIMtN2w4JZs1K7h1_Y2qrT6RuQXKtgBvBBu3iIIdrDg/edit?gid=385652933))
2. `update-bear-weeks.py` — computes current ISO week, looks up current/prev/next date ranges, updates the 6 vars in `bear-notes.jsonc`, reloads Hammerspoon
3. **Scheduling**: `stepper.lua` runs the script on Hammerspoon load + daily at 7am via `hs.timer.doAt`. (Previously used a launchd plist, but launchd can't access `~/Library/CloudStorage/` paths due to macOS TCC restrictions.)

## Files

| File | Purpose |
|------|---------|
| `fetch-week-data.sh` | One-time: fetches week data from Google Sheets via `gws` → `week-data.json` |
| `update-bear-weeks.py` | Weekly: computes week, updates JSONC vars, reloads Hammerspoon |
| `week-data.json` | Cached week lookup (53 entries) |
| `stepper.lua` (weekUpdate section) | Runs script on load + daily 7am via `hs.timer.doAt` |
| [`../../data/bear-notes.jsonc`](../../data/bear-notes.jsonc) | The file being updated (vars block) |

## Why Hammerspoon, not launchd?

See [how-we-auto-update.md](how-we-auto-update.md) — launchd agents can't access `~/Library/CloudStorage/` due to macOS TCC restrictions. Hammerspoon already has the right permissions and is always running.

## Manual Run

```bash
python3 update-bear-weeks.py
```

## Year Boundary

At the start of each new year, re-run `fetch-week-data.sh` against the new year's tab in the spreadsheet to refresh `week-data.json`.
