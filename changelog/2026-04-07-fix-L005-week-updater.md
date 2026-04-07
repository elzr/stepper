# Fix: [L005](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts) weekly bear-notes updater broken for 3 weeks

**Date**: 2026-04-07

## Contents

- [Root cause](#root-cause)
- [Fixes](#fixes)
- [TDD test suite](#tdd-test-suite)
- [Files changed](#files-changed)

---

**Symptom**: ==🔴Bear note hotkeys (Hyper+D/W/T) pointed at last week's notes every Monday==. The auto-updater for [bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc) was silently failing, requiring manual edits each week.

---

## Root cause

==🔴`update-bear-weeks.py` had `os.path.join(SCRIPT_DIR, "..", "..", "..")` — three parent levels instead of two==. The script lives at `stepper/features/L005-.../`, so three `..` resolved to `hammerspoon/` instead of `stepper/`. It was looking for `hammerspoon/data/bear-notes.jsonc` which doesn't exist.

==🟣This path was wrong from the original commit== — the script never actually worked via Hammerspoon's `hs.task`. The `FileNotFoundError` was captured by the callback as stderr, but easy to miss in the console. Manual runs from the CLI happened to work because the user would notice the stale values and fix the file by hand.

---

## Fixes

**1. Path fix** — ==🟢`"..", "..", ".."` → `"..", ".."`== in `PROJECT_ROOT`.

**2. Synchronous on-load** — ==🔵Moved the on-load week check from async `hs.task` to synchronous `hs.execute` at the top of [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua), before bear-hud loads==. This ensures hotkeys bind to current week names in a single reload — no double-reload cascade. A deferred `print()` at the end of the file logs the result to the HS console (since `hs.execute` runs before the console extension loads).

**3. Async for timer/wake** — Timer and wake triggers still use async `hs.task` with `hs.reload()` on change, since they fire mid-session. ==🟢`updateBearWeeksAsync()` is a global== so it can be invoked from the HS CLI for testing.

**4. Monday-only timer** — ==🔵Changed from daily 7am to Monday 00:01==. Bear-notes week vars are the only weekly update in the config; no reason to check daily.

**5. Reload script resilience** — [hs-reload.sh](openfile:///Users/sara/bin/hs-reload.sh) now ==🟢retries the readiness check in a loop (up to 5× 500ms)==, tolerating mid-reload Mach port disconnects (exit code 69) instead of failing on the first attempt.

**6. Script refactored for testability** — ==🟣Extracted `compute_weeks()`, `update_jsonc_content()`, and `update_file()` from `main()`==. Removed the `hs-reload.sh` call from the script (reload is now the caller's responsibility — either `hs.reload()` in Lua or nothing when run standalone). Prints `CHANGED` as last stdout line so Lua callback can detect updates.

---

## TDD test suite

==🔵First red/green TDD cycle for the stepper project==. 14 tests in [test_update_bear_weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/test_update_bear_weeks.py):

| Suite | Tests | What it catches |
|-------|-------|----------------|
| `TestPathResolution` | 3 | ==🔴The exact 3-week bug== — `PROJECT_ROOT` must end with `stepper`, JSONC and week-data files must exist |
| `TestComputeWeeks` | 5 | Week calculation, year-boundary wraparound (week 1↔53), all 6 keys present |
| `TestUpdateContent` | 4 | Regex update of stale values, idempotency, comment preservation |
| `TestEndToEnd` | 2 | Full file update with temp files, no-write-when-current (mtime check) |

Run: `python3 test_update_bear_weeks.py -v`

---

## Files changed

- [update-bear-weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/update-bear-weeks.py): Path fix, refactored into testable functions, removed hs-reload call
- [test_update_bear_weeks.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L005-weekly-updater-of-Bear-shortcuts/test_update_bear_weeks.py): New — 14-test suite
- [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua): Synchronous on-load update, async wake/timer with reload, Monday-only timer, deferred console log
- [hs-reload.sh](openfile:///Users/sara/bin/hs-reload.sh): Retry loop for readiness check
- [bear-notes.jsonc](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/bear-notes.jsonc): Updated to week 15 (by the fix itself)
