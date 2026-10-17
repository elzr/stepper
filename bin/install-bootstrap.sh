#!/bin/bash
# Installs bootstrap-init.lua as ~/.hammerspoon/init.lua: a plain local copy, never a symlink into
# Dropbox, so Hammerspoon (and hs-reload.sh) still start when Dropbox can't be read. Rerun it after
# editing bootstrap-init.lua; the Hammerspoon console says when the installed copy has fallen behind.
# rm first: cp onto a symlink would write through it, into the file it points at.
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/bootstrap-init.lua"
DST="$HOME/.hammerspoon/init.lua"
[ -L "$DST" ] && rm "$DST"
cp "$SRC" "$DST"
echo "installed $DST from $SRC"
