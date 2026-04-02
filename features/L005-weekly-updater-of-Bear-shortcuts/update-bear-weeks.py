#!/usr/bin/env python3
"""Update bear-notes.jsonc week variables to the current ISO week.

Reads week-data.json (same directory) for date-range strings,
computes current/prev/next week numbers, updates the vars block
in data/bear-notes.jsonc via line-by-line regex, then reloads
Hammerspoon.

Idempotent: multiple runs in the same week produce the same result.
"""

import datetime
import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
JSONC_PATH = os.path.join(PROJECT_ROOT, "data", "bear-notes.jsonc")
WEEK_DATA_PATH = os.path.join(SCRIPT_DIR, "week-data.json")
HS_RELOAD = os.path.expanduser("~/bin/hs-reload.sh")

def main():
    # Load week data
    with open(WEEK_DATA_PATH) as f:
        weeks = json.load(f)

    total_weeks = len(weeks)

    # Current ISO week
    today = datetime.date.today()
    current_week = today.isocalendar()[1]

    # Prev/next with wraparound
    prev_week = total_weeks if current_week == 1 else current_week - 1
    next_week = 1 if current_week == total_weeks else current_week + 1

    current_days = weeks.get(str(current_week))
    prev_days = weeks.get(str(prev_week))
    next_days = weeks.get(str(next_week))

    if not all([current_days, prev_days, next_days]):
        print(f"ERROR: Missing week data for weeks {prev_week}/{current_week}/{next_week}", file=sys.stderr)
        sys.exit(1)

    print(f"Week {current_week}: {current_days} (prev: w{prev_week} {prev_days}, next: w{next_week} {next_days})")

    # Read JSONC file
    with open(JSONC_PATH) as f:
        lines = f.readlines()

    # Update the 6 var lines using regex (preserves comments and whitespace)
    replacements = {
        "weekNum": str(current_week),
        "weekDays": current_days,
        "pastWeekNum": str(prev_week),
        "pastWeekDays": prev_days,
        "nextWeekNum": str(next_week),
        "nextWeekDays": next_days,
    }

    changed = False
    for i, line in enumerate(lines):
        for var_name, var_value in replacements.items():
            # Match: "varName": "value"  (with optional trailing comma and comment)
            pattern = rf'("' + re.escape(var_name) + r'":\s*")([^"]*?)(")'
            match = re.search(pattern, line)
            if match and match.group(2) != var_value:
                lines[i] = re.sub(pattern, rf'\g<1>{var_value}\3', line)
                changed = True

    if not changed:
        print("Already up to date.")
        return

    # Write updated file
    with open(JSONC_PATH, "w") as f:
        f.writelines(lines)
    print(f"Updated {JSONC_PATH}")

    # Reload Hammerspoon
    try:
        subprocess.run([HS_RELOAD], check=True, timeout=10)
        print("Hammerspoon reloaded.")
    except Exception as e:
        print(f"Warning: Hammerspoon reload failed: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
