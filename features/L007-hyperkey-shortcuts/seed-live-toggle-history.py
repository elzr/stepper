#!/usr/bin/env python3
"""Seed data/live-toggle-history.jsonl from git: every committed version of
data/live-toggle-hotkeys.json since 2026-02-12, a "set" line for each key whose window
changed and a "freed" line for each key that went, dated by the slot's own setAt when it
has one, else by the commit. Then the four ◆ letters that were fixed Bear-note keys until
2026-10-13 (I, M, R, S), as the live Bear slots they became.

Run once, from anywhere; it refuses to run over a history that already exists.
bear-hud.lua appends to the file from then on (recordHistory).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SLOTS = "data/live-toggle-hotkeys.json"
OUT = ROOT / "data/live-toggle-history.jsonl"
BEAR = "net.shinyfrog.bear"
# The fixed note keys made live on 2026-10-13, and when bear-notes.jsonc first gave them
# their note (git log -S on the key)
MADE_LIVE = {"I": "_index 2026", "M": "_money 2026", "R": "_app rcmd", "S": "_topsight 2026"}
NOTE_SINCE = "2026-02-16T22:41:54"
MIGRATED_AT = "2026-10-13T12:00:00"


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def same(a, b):
    return a and b and (a.get("winID"), a.get("bundleID"), a.get("title")) == (b.get("winID"), b.get("bundleID"), b.get("title"))


def line(event, key, slot, at, by):
    return {"at": at, "event": event, "key": key, "by": by, "bundleID": slot.get("bundleID"),
            "app": slot.get("app"), "doc": slot.get("doc"), "title": slot.get("title"), "winID": slot.get("winID")}


def main():
    if OUT.exists() and OUT.stat().st_size > 0:
        sys.exit(f"{OUT} already has lines; not seeding over it")
    versions = []
    for row in reversed(git("log", "--format=%H %aI", "--", SLOTS).split("\n")):
        if not row:
            continue
        sha, at = row.split()
        versions.append((at[:19], json.loads(git("show", f"{sha}:{SLOTS}"))))
    # The working copy, less the keys made live today: their lines come below
    current = {k: v for k, v in json.loads((ROOT / SLOTS).read_text()).items() if k not in MADE_LIVE}
    versions.append(("", current))

    lines, prev = [], {}
    for at, slots in versions:
        for key in sorted(set(prev) | set(slots)):
            old, new = prev.get(key), slots.get(key)
            if new and not same(old, new):
                lines.append(line("set", key, new, new.get("setAt") or at, "R⌥◆"))
            elif old and not new:
                lines.append(line("freed", key, old, at, "R⌥◆"))
        prev = slots
    for key, title in MADE_LIVE.items():
        slot = {"bundleID": BEAR, "app": "Bear", "doc": title, "title": title}
        lines.append(line("set", key, slot, NOTE_SINCE, "bear-notes.jsonc, a fixed note key"))
        lines.append(line("set", key, slot, MIGRATED_AT, "made a live slot, holding its note"))
    lines.sort(key=lambda e: e["at"])
    OUT.write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in lines))
    print(f"{len(lines)} lines → {OUT}")


if __name__ == "__main__":
    main()
