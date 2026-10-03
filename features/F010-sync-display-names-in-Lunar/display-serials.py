#!/usr/bin/env python3
"""Print every connected monitor's EDID identity: both serials, model, manufacture date.

Usage:
    display-serials.py            # one snapshot
    display-serials.py --watch    # a new snapshot whenever the set of monitors changes
    display-serials.py --json     # one snapshot as JSON rows (for lua/displayguard.lua)

An EDID carries two serials: a 4-byte numeric one, which macOS uses to tell
displays apart, and an optional text one. When monitors share the numeric serial
(both Samsung LS37D70xE carry the ASCII letters "HYX0" there), macOS can only
tell them apart by port — the root of F010's crossed sliders.

Read-only: ioreg for the monitor on each framebuffer, CoreGraphics + CoreDisplay
(IODisplayLocation, private) for which macOS display sits on each framebuffer.
"""

import ctypes
import json
import plistlib
import re
import subprocess
import sys
import time
from collections import defaultdict

UTF8 = 0x08000100

class CGRect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double),
                ("w", ctypes.c_double), ("h", ctypes.c_double)]

def monitors():
    """{port: ProductAttributes + downstream transport} for each framebuffer with a monitor."""
    found = {}
    for n in range(8):
        port = f"dispext{n}"
        out = subprocess.run(["ioreg", "-a", "-l", "-r", "-n", port, "-d", "2"],
                             capture_output=True).stdout
        for node in plistlib.loads(out) if out else []:
            for child in node.get("IORegistryEntryChildren", []):
                attrs = child.get("DisplayAttributes", {}).get("ProductAttributes")
                if attrs:
                    found[port] = dict(attrs, Transport=child.get("Transport", {}).get("Downstream", "?"))
    return found

def macos_displays():
    """{port: (display id, x, y, rotation, asleep)} for each online macOS display on an external framebuffer."""
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cd = ctypes.CDLL("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")
    cg.CGGetOnlineDisplayList.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
    cg.CGDisplayBounds.restype = CGRect
    cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
    cg.CGDisplayRotation.restype = ctypes.c_double
    cg.CGDisplayRotation.argtypes = [ctypes.c_uint32]
    cg.CGDisplayIsAsleep.restype = ctypes.c_uint32
    cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFDictionaryGetValue.restype = ctypes.c_void_p
    cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    cd.CoreDisplay_DisplayCreateInfoDictionary.restype = ctypes.c_void_p
    cd.CoreDisplay_DisplayCreateInfoDictionary.argtypes = [ctypes.c_uint32]

    ids = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32()
    cg.CGGetOnlineDisplayList(16, ids, ctypes.byref(count))
    key = cf.CFStringCreateWithCString(None, b"IODisplayLocation", UTF8)
    found = {}
    for did in ids[:count.value]:
        info = cd.CoreDisplay_DisplayCreateInfoDictionary(did)
        if not info:
            continue
        value = cf.CFDictionaryGetValue(info, key)
        buf = ctypes.create_string_buffer(512)
        ok = bool(value) and cf.CFStringGetCString(value, buf, len(buf), UTF8)
        cf.CFRelease(info)
        port = re.search(r"/(dispext\d+)@", buf.value.decode() if ok else "")
        if port:
            b = cg.CGDisplayBounds(did)
            found[port.group(1)] = (did, int(b.x), int(b.y), int(cg.CGDisplayRotation(did)),
                                    bool(cg.CGDisplayIsAsleep(did)))
    cf.CFRelease(key)
    return found

def numeric(serial):
    """Numeric serial with its EDID bytes (bytes 12–15), plus their ASCII when all printable."""
    raw = serial.to_bytes(4, "little")
    text = f' = "{raw.decode("ascii")}"' if all(0x20 < b < 0x7F for b in raw) else ""
    return f"{serial} [{raw.hex(' ')}{text}]"

def snapshot(found):
    where = macos_displays()
    lines = []
    for port in sorted(found):
        a = found[port]
        did, x, y, rot, _ = where.get(port, ("?", "?", "?", "?", False))
        lines.append(f"{port}: display {did} at ({x},{y}) rot {rot} — {a.get('ManufacturerID')} "
                     f"{a.get('ProductName')} model {a.get('ProductID')}, made {a.get('YearOfManufacture')} "
                     f"week {a.get('WeekOfManufacture')}, via {a['Transport']}")
        lines.append(f"    numeric serial {numeric(a.get('SerialNumber', 0))}   "
                     f"text serial {a.get('AlphanumericSerialNumber', '—')}")
    shared = defaultdict(list)
    for port, a in found.items():
        shared[(a.get("ManufacturerID"), a.get("ProductID"), a.get("SerialNumber"))].append(port)
    for ports in shared.values():
        if len(ports) > 1:
            lines.append(f"  ⚠ {', '.join(sorted(ports))} share vendor + model + numeric serial: "
                         "macOS can only tell them apart by port")
    return "\n".join(lines)

def identity(found):
    return sorted((p, a.get("ProductID"), a.get("SerialNumber"), a.get("AlphanumericSerialNumber"))
                  for p, a in found.items())

def rows(found):
    """One JSON-ready dict per framebuffer with a monitor: identity plus macOS's display for it."""
    where = macos_displays()
    out = []
    for port in sorted(found):
        a = found[port]
        did, x, y, rot, asleep = where.get(port, (None, None, None, None, False))
        out.append({"port": port, "displayID": did, "x": x, "y": y, "rotation": rot, "asleep": asleep,
                    "serial": a.get("AlphanumericSerialNumber"), "numericSerial": a.get("SerialNumber"),
                    "manufacturer": a.get("ManufacturerID"), "product": a.get("ProductName"),
                    "productID": a.get("ProductID"), "transport": a.get("Transport")})
    return out

def main():
    if "--json" in sys.argv:
        print(json.dumps(rows(monitors())))
        return
    if "--watch" not in sys.argv:
        print(snapshot(monitors()))
        return
    last = None
    while True:
        found = monitors()
        if identity(found) != last:
            last = identity(found)
            print(f"--- {time.strftime('%H:%M:%S')}  {len(found)} external monitor(s)", flush=True)
            print(snapshot(found), flush=True)
        time.sleep(2)

if __name__ == "__main__":
    main()
