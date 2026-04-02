#!/bin/bash
# Fetches week data from the 2026 tab of the year-weeks spreadsheet.
# Outputs week-data.json in the same directory.
# Re-run against next year's tab when the year changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHEET_ID="1nIMtN2w4JZs1K7h1_Y2qrT6RuQXKtgBvBBu3iIIdrDg"
# Note: the ! in the range requires careful quoting
RANGE="2026"'!'"A3:F55"

RAW=$(gws sheets spreadsheets values get --params "{\"spreadsheetId\": \"$SHEET_ID\", \"range\": \"$RANGE\"}")

# Parse the gws JSON output into {weekNum: dateRange} format
python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
weeks = {}
for row in data.get('values', []):
    if len(row) >= 6:
        weeks[row[0]] = row[5]  # column F = 'start-end w year'
print(json.dumps(weeks, indent=2))
" <<< "$RAW" > "$SCRIPT_DIR/week-data.json"

echo "Wrote $(python3 -c "import json; print(len(json.load(open('$SCRIPT_DIR/week-data.json'))))"  ) weeks to $SCRIPT_DIR/week-data.json"
