#!/bin/bash
# Dump Hammerspoon console output to stdout.
# Usage: hs-console.sh [lines]  (default: 30, 0 = all)
# ~/bin/hs, not the bare CLI: that one waited forever on a socket stdin (2026-10-17)
HS=~/bin/hs
LINES=${1:-30}
if [ "$LINES" = "0" ]; then
  $HS -c "return hs.console.getConsole()" 2>&1
else
  $HS -c "local c = hs.console.getConsole() local lines = {} for l in c:gmatch('[^\n]+') do lines[#lines+1] = l end local out = {} for i = math.max(1, #lines - $LINES + 1), #lines do out[#out+1] = lines[i] end return table.concat(out, '\n')" 2>&1
fi
