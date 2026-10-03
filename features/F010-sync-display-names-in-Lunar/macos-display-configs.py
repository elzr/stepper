#!/usr/bin/env python3
"""Read-only probe: every display arrangement macOS has saved, one line per display.

macOS keeps one arrangement per *exact set* of display UUIDs, in
/Library/Preferences/com.apple.windowserver.displays.plist (the per-user ByHost
copy is stale on recent macOS). A set it has never seen gets defaults: rotation
0, the "default" scaled mode (1920x1080 HiDPI on a 4K panel) and a slot next to
the main display. The two Samsung LS37D70xE share a numeric EDID serial, so a
hub reset can hand them a UUID pair macOS has never seen together — that is how
the portrait arrangement gets lost (2026-10-03 12:25:56).

Usage:
    python3 macos-display-configs.py            # all saved arrangements
    python3 macos-display-configs.py FD24B45E   # only arrangements naming these UUID prefixes
"""
import glob
import json
import os
import subprocess
import sys

FILES = ["/Library/Preferences/com.apple.windowserver.displays.plist"] + glob.glob(
    os.path.expanduser("~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist")
)


def configs(node, path=""):
    """Yield (path, config) for every Configs list anywhere in the plist."""
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "Configs" and isinstance(val, list):
                for i, cfg in enumerate(val):
                    yield "{}[{}]".format(path, i), cfg
            else:
                yield from configs(val, path + "/" + key)
    elif isinstance(node, list):
        for i, val in enumerate(node):
            yield from configs(val, "{}[{}]".format(path, i))


def main():
    wanted = [w.upper() for w in sys.argv[1:]]
    for f in FILES:
        print("=====", f)
        data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", f]))
        for key, val in data.items():
            if not isinstance(val, (dict, list)):
                print("  {}: {}".format(key, val))
        for path, cfg in configs(data):
            dc = cfg.get("DisplayConfig", [])
            uuids = [e.get("UUID", "?").upper() for e in dc]
            if wanted and not any(u.startswith(w) for u in uuids for w in wanted):
                continue
            print("  {} v={} n={}".format(path, cfg.get("ConfigVersion"), len(dc)))
            for e in dc:
                c = e.get("CurrentInfo", {})
                print(
                    "     {} rot={:>3} {}x{}@{} scale={} origin=({},{})".format(
                        e.get("UUID", "?")[:8], e.get("Rotation"), c.get("Wide"), c.get("High"),
                        c.get("Hz"), c.get("Scale"), c.get("OriginX"), c.get("OriginY"),
                    )
                )


if __name__ == "__main__":
    main()
