#!/usr/bin/env python3
"""Keep Lunar's display names and DDC wiring in sync with physical positions.

Usage:
    lunar-sync-names.py '{"<uuid>": {"name": "←Left", "id": 4}, ...}'

Each key is a macOS display UUID (Lunar's `serial` field). `name` is the position
name to show in Lunar; `id` is the CGDirectDisplayID macOS currently assigns to
that UUID (hs.screen:id()).

Lunar is restarted when any of these hold:
  - a stored name differs from the expected one
  - the running Lunar pairs a UUID with a different display ID than macOS does.
    Identical monitors can swap IDs on a reconnect blip; Lunar keeps its old
    display objects (`lunar refresh-displays` doesn't fix that).
  - a slider's DDC reaches a different monitor than the one at its position.
    Lunar wires DDC at launch from the display IDs it saved last session, so a
    launch after macOS swapped the IDs of identical monitors comes up crossed
    even though its live IDs look right.

Before relaunching, names and IDs are written into Lunar's prefs while it is quit,
so it can't overwrite them and wires DDC from the current IDs.
Exits 0 if Lunar was restarted, 1 if nothing to do, 2 on error.
"""

import ctypes
import json
import plistlib
import re
import subprocess
import sys
import time
import traceback

LUNAR_DOMAIN = "fyi.lunar.Lunar"
LUNAR_BIN = "/Applications/Lunar.app/Contents/MacOS/Lunar"
TMP_PLIST = "/tmp/lunar-sync-names.plist"
RECHECK_DELAY = 3    # seconds — let Lunar finish its own reconfiguration first
QUIT_TIMEOUT = 10    # seconds
LAUNCH_TIMEOUT = 30  # seconds for the relaunched app to answer CLI calls
DDC_SETTLE = 3       # seconds for Lunar's DDC detection after it answers

def read_plist():
    """Read Lunar's preferences via defaults export."""
    result = subprocess.run(
        ["defaults", "export", LUNAR_DOMAIN, TMP_PLIST],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error reading Lunar prefs: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    with open(TMP_PLIST, "rb") as f:
        return plistlib.load(f)

def write_plist(data):
    """Write modified preferences back via defaults import."""
    with open(TMP_PLIST, "wb") as f:
        plistlib.dump(data, f)
    result = subprocess.run(
        ["defaults", "import", LUNAR_DOMAIN, TMP_PLIST],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error writing Lunar prefs: {result.stderr}", file=sys.stderr)
        sys.exit(2)

def apply_expected(displays, expected, fields=("name",)):
    """Set expected fields on matching entries in place; return descriptions of changes."""
    changed = []
    for i, d_str in enumerate(displays):
        d = json.loads(d_str)
        spec = expected.get(d.get("serial", ""))
        diffs = [f for f in fields if spec and d.get(f) != spec[f]]
        for f in diffs:
            changed.append(f"{spec['name']}: {f} {d.get(f)!r} -> {spec[f]!r}")
            d[f] = spec[f]
        if diffs:
            displays[i] = json.dumps(d)
    return changed

def lunar(*args, timeout=20):
    """Run a Lunar CLI command against the running app; return stdout ('' on failure).

    --remote: never fall back to a CLI-only instance, whose state isn't the app's.
    """
    try:
        return subprocess.run([LUNAR_BIN, "@", "--remote", *args],
                              capture_output=True, text=True, timeout=timeout).stdout
    except (subprocess.TimeoutExpired, OSError):
        return ""

def lunar_running():
    return subprocess.run(["pgrep", "-x", "Lunar"], capture_output=True).returncode == 0

def stale_pairings(expected):
    """UUIDs the running Lunar pairs with a different display ID than macOS does."""
    try:
        live = json.loads(lunar("displays", "--json"))
    except json.JSONDecodeError:
        return []  # can't tell — don't restart on a guess
    entries = live.values() if isinstance(live, dict) else live
    return [
        f"Stale Lunar mapping: {d['serial'][:8]} is id {d['id']} in Lunar, {expected[d['serial']]['id']} in macOS"
        for d in entries
        if d.get("serial") in expected and d.get("id") != expected[d["serial"]]["id"]
    ]

def monitor_serials(expected):
    """{uuid: EDID alphanumeric serial of the physical monitor macOS shows at that display}.

    CoreDisplay gives each display's framebuffer (IODisplayLocation, private API);
    ioreg gives the serial of the monitor attached to that framebuffer. Identical
    monitors only differ by this serial. Returns {} if CoreDisplay is unavailable.
    """
    try:
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cd = ctypes.CDLL("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")
        create_info = cd.CoreDisplay_DisplayCreateInfoDictionary
    except (OSError, AttributeError):
        return {}
    utf8 = 0x08000100
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFDictionaryGetValue.restype = ctypes.c_void_p
    cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    create_info.restype = ctypes.c_void_p
    create_info.argtypes = [ctypes.c_uint32]

    serials = {}
    key = cf.CFStringCreateWithCString(None, b"IODisplayLocation", utf8)
    for uuid, spec in expected.items():
        info = create_info(spec["id"])
        if not info:
            continue
        value = cf.CFDictionaryGetValue(info, key)
        buf = ctypes.create_string_buffer(512)
        ok = bool(value) and cf.CFStringGetCString(value, buf, len(buf), utf8)
        cf.CFRelease(info)
        # ".../dispext2@8A000000/AppleCLCD2" → "dispext2" (the built-in is disp0: skipped)
        port = re.search(r"/(dispext\d+)@[^/]*/AppleCLCD2$", buf.value.decode() if ok else "")
        if not port:
            continue
        out = subprocess.run(["ioreg", "-a", "-l", "-r", "-n", port.group(1), "-d", "2"],
                             capture_output=True).stdout
        for node in plistlib.loads(out) if out else []:
            for child in node.get("IORegistryEntryChildren", []):
                serial = child.get("DisplayAttributes", {}).get("ProductAttributes", {}).get("AlphanumericSerialNumber")
                if serial:
                    serials[uuid] = serial
    cf.CFRelease(key)
    return serials

def crossed_ddc(expected):
    """Sliders whose DDC reaches a different monitor than the one at their position.

    `lunar edid` reads the EDID back through the DDC service Lunar matched to that
    display — the same service its brightness slider writes to.
    """
    crossed = []
    for uuid, want in monitor_serials(expected).items():
        # EDID reads take well under a second; one that hangs is a monitor not answering
        got = re.search(r"Display Product Serial Number: '([^']*)'", lunar("edid", uuid, timeout=5))
        if got and got.group(1) != want:
            crossed.append(f"Crossed DDC: {expected[uuid]['name']} drives {got.group(1)}, should drive {want}")
    return crossed

def displays_asleep(expected):
    """True if any of the displays is asleep — DDC to a sleeping monitor can hang."""
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cg.CGDisplayIsAsleep.restype = ctypes.c_uint32
    cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    return any(cg.CGDisplayIsAsleep(spec["id"]) for spec in expected.values())

def lunar_problems(expected):
    """Ways the running Lunar disagrees with macOS (crossed DDC follows from stale IDs)."""
    return stale_pairings(expected) or crossed_ddc(expected)

def quit_lunar():
    subprocess.run(["osascript", "-e", 'tell application "Lunar" to quit'], capture_output=True)
    deadline = time.time() + QUIT_TIMEOUT
    while lunar_running():
        if time.time() > deadline:
            return False
        time.sleep(0.25)
    return True

def wait_for_lunar():
    """Wait for the relaunched app to answer, then give its DDC detection time to finish."""
    deadline = time.time() + LAUNCH_TIMEOUT
    while not lunar("displays", "--json").strip():
        if time.time() > deadline:
            return False
        time.sleep(1)
    time.sleep(DDC_SETTLE)
    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: lunar-sync-names.py '{uuid: {name, id}, ...}'", file=sys.stderr)
        sys.exit(2)

    expected = json.loads(sys.argv[1])
    if displays_asleep(expected):
        # Lunar would also push DDC to sleeping monitors on relaunch; Hammerspoon re-checks on wake
        print("Displays asleep — skipping")
        sys.exit(1)
    running = lunar_running()

    renames = apply_expected(list(read_plist().get("displays", [])), expected)
    problems = lunar_problems(expected) if running else []
    if problems:
        time.sleep(RECHECK_DELAY)
        problems = lunar_problems(expected)

    if not renames and not problems:
        print("No changes needed")
        sys.exit(1)

    for p in problems:
        print(p)

    if running and not quit_lunar():
        print("Lunar didn't quit — leaving its prefs alone", file=sys.stderr)
        sys.exit(2)

    # Re-read after quitting: Lunar may have flushed its own state on the way out.
    # Fixing the stored ids too is what makes the relaunch wire DDC correctly.
    data = read_plist()
    displays = data.get("displays", [])
    changes = apply_expected(displays, expected, ("name", "id"))
    if changes:
        data["displays"] = displays
        write_plist(data)
        for c in changes:
            print(f"Updated: {c}")

    subprocess.run(["open", "-a", "Lunar"])
    print("Lunar restarted")

    if not wait_for_lunar():
        print("Lunar didn't come back up to verify DDC wiring")
        return
    still = crossed_ddc(expected)
    for c in still:
        print(f"Still {c[0].lower()}{c[1:]}")
    if not still:
        print("DDC wiring verified")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        # An uncaught exception would exit 1, which reads as "nothing to do"
        traceback.print_exc()
        sys.exit(2)
