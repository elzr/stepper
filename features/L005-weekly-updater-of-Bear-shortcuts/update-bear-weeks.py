#!/usr/bin/env python3
"""Update bear-notes.jsonc week variables to the current ISO week.

Reads week-data.json (same directory) for date-range strings,
computes current/prev/next week numbers, updates the vars block
in data/bear-notes.jsonc via line-by-line regex.

Idempotent: multiple runs in the same week produce the same result.
Prints "CHANGED" as last line when the file was updated, so callers
(e.g. stepper.lua) can decide whether to reload Hammerspoon.
"""

import datetime
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
JSONC_PATH = os.path.join(PROJECT_ROOT, "data", "bear-notes.jsonc")
WEEK_DATA_PATH = os.path.join(SCRIPT_DIR, "week-data.json")


def compute_weeks(today=None):
    """Return a dict of the 6 bear-notes.jsonc vars for the given date.

    Keys: weekNum, weekDays, pastWeekNum, pastWeekDays, nextWeekNum, nextWeekDays.
    All values are strings. Raises SystemExit if week-data.json is missing entries.
    """
    if today is None:
        today = datetime.date.today()

    with open(WEEK_DATA_PATH) as f:
        weeks = json.load(f)

    total_weeks = len(weeks)
    current_week = today.isocalendar()[1]
    prev_week = total_weeks if current_week == 1 else current_week - 1
    next_week = 1 if current_week == total_weeks else current_week + 1

    current_days = weeks.get(str(current_week))
    prev_days = weeks.get(str(prev_week))
    next_days = weeks.get(str(next_week))

    if not all([current_days, prev_days, next_days]):
        print(f"ERROR: Missing week data for weeks {prev_week}/{current_week}/{next_week}", file=sys.stderr)
        sys.exit(1)

    return {
        "weekNum": str(current_week),
        "weekDays": current_days,
        "pastWeekNum": str(prev_week),
        "pastWeekDays": prev_days,
        "nextWeekNum": str(next_week),
        "nextWeekDays": next_days,
    }


def update_jsonc_content(lines, replacements):
    """Apply replacements to JSONC lines. Returns (new_lines, changed).

    Each replacement matches "varName": "value" and swaps the value,
    preserving comments and whitespace.
    """
    changed = False
    new_lines = list(lines)
    for i, line in enumerate(new_lines):
        for var_name, var_value in replacements.items():
            pattern = rf'("' + re.escape(var_name) + r'":\s*")([^"]*?)(")'
            match = re.search(pattern, line)
            if match and match.group(2) != var_value:
                new_lines[i] = re.sub(pattern, rf'\g<1>{var_value}\3', line)
                line = new_lines[i]  # update for subsequent replacements on same line
                changed = True
    return new_lines, changed


def update_file(jsonc_path=None, today=None):
    """Compute current weeks and update a JSONC file. Returns True if changed."""
    if jsonc_path is None:
        jsonc_path = JSONC_PATH

    replacements = compute_weeks(today)

    with open(jsonc_path) as f:
        lines = f.readlines()

    new_lines, changed = update_jsonc_content(lines, replacements)

    if changed:
        with open(jsonc_path, "w") as f:
            f.writelines(new_lines)

    return changed


def main():
    replacements = compute_weeks()
    week = replacements["weekNum"]
    days = replacements["weekDays"]
    prev = replacements["pastWeekNum"]
    prev_days = replacements["pastWeekDays"]
    nxt = replacements["nextWeekNum"]
    nxt_days = replacements["nextWeekDays"]
    print(f"Week {week}: {days} (prev: w{prev} {prev_days}, next: w{nxt} {nxt_days})")

    changed = update_file()
    if changed:
        print(f"Updated {JSONC_PATH}")
        print("CHANGED")
    else:
        print("Already up to date.")


if __name__ == "__main__":
    main()
