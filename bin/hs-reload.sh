#!/bin/bash
# Reload Hammerspoon and wait for it to be ready.
# Retries the readiness check because on-load tasks (e.g. weekUpdate)
# may trigger a second hs.reload(), invalidating the first connection.
# init.lua loads its modules on a timer after showing the reload notice, so the CLI answers
# before they are in: ready means its hsLoaded is set.
# </dev/null on every call: when stdin is a pipe (as in a Claude Code session), hs runs its -c
# and then reads stdin for more, waiting forever. timeout is the backstop.
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
$HS -c "hs.reload()" </dev/null &>/dev/null &
for i in $(seq 1 40); do
  sleep 0.5
  result=$(/opt/homebrew/bin/timeout 3 $HS -c "return hsLoaded and string.format('ready in %.1f s', hsLoadSeconds or 0) or 'loading'" </dev/null 2>/dev/null) && [ "${result#ready}" != "$result" ] && echo "$result" && exit 0
done
echo "timeout waiting for Hammerspoon" >&2
exit 1
