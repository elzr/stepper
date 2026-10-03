# F010 — sync-display-names-in-Lunar

> Keep [Lunar](https://lunar.fyi/)'s display names **and its DDC wiring** in line with where each monitor physically sits, so the "←Left" slider always dims the left monitor. Driven from Hammerspoon by [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua), executed by [lunar-sync-names.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/lunar-sync-names.py).

**Status:** active. **Created:** 2026-03-02. **Reworked:** 2026-10-03 (two portrait LGs replaced by two Samsung LS37D70xE that share a numeric serial).

## Contents

- [Problem](#problem)
- [Solution](#solution)
- [Position → Name Mapping](#position--name-mapping)
- [Lunar setting this relies on](#lunar-setting-this-relies-on)
- [Diagnostics](#diagnostics)
- [Files](#files)
- [Manual Trigger](#manual-trigger)
- [How Lunar Stores Display Data](#how-lunar-stores-display-data)
- [Case studies](#case-studies)

## Problem

The quad-32 setup is the built-in display + 2× LG HDR 4K (top/center, distinct serials) + ==🔵2× Samsung LS37D70xE in portrait (left/right)==. A monitor's EDID carries two serials: a **numeric** one, which macOS (and Lunar) use to tell displays apart, and a **text** one. Both Samsungs report ==🔴the same numeric serial (`811096392`)== — a fixed value, not a per-unit number — so they're indistinguishable in everything macOS uses to identify a display. Their unique serials (`HNTL300013`, `HNTL300014`) are only in the text field, which macOS keeps in IOKit but doesn't use for identification. macOS therefore tells them apart only by port, via per-port display UUIDs and IDs that it reshuffles across reboots and reconnects. The LGs report distinct numeric serials (`728780`, `11249`), so they don't have this problem.

Lunar gets this wrong in three distinct ways:

1. ==🔴Names on the wrong UUIDs== — the original F010 problem. Lunar keys names by UUID; when macOS reassigns UUIDs, the position names land on the wrong monitors.
2. ==🔴Stale display objects after a reconnect blip== — a monitor drops and returns (screen count 5 → 4 → 5) and macOS swaps the display IDs of the two Samsungs. The running Lunar keeps its old UUID ↔ ID pairing, so its sliders act on the other monitor. `lunar refresh-displays` does **not** fix this; only a restart does.
3. ==🔴Crossed DDC at launch== — Lunar wires each display to a DDC port at launch using the display IDs it **saved last session**, then refreshes the IDs. If macOS swapped the pair's IDs while Lunar wasn't running (every reboot is a coin flip), the sliders come up crossed even though Lunar's live IDs look right. Reproduced on 2026-10-03 by swapping the two saved `id`s: the next launch came up crossed, and the one after (with re-saved IDs) was correct.

Symptoms in Lunar's window: a Samsung slider labeled "⊙Middle Center", a display showing "No controls available" (no DDC port matched), the real Middle Center LG with no slider at all.

## Solution

Hammerspoon always knows the truth — position from screen frames ([screenswitch.buildScreenMap()](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenswitch.lua)), plus each screen's UUID and display ID — and passes it to the script as `{uuid: {name, id}}`.

### Checks

The script restarts Lunar only if one of these fails:

| Check | Catches | How |
|-------|---------|-----|
| Names | problem 1 | stored `name` per UUID in Lunar's prefs |
| Live pairing | problem 2 | `lunar displays --json` UUID ↔ ID vs macOS |
| DDC wiring | problem 3 (and any other crossing) | ==🟢EDID read back through each slider's DDC port== (`lunar edid`) vs the serial of the monitor macOS has at that display |

The DDC check's ground truth: CoreDisplay's `IODisplayLocation` gives each display's framebuffer port (`dispextN`, private API via `ctypes`), and `ioreg` gives the alphanumeric serial of the monitor on that port. Problems found are re-checked after 3s before acting, so a reconfiguration still in progress isn't mistaken for a crossing.

### Restart

==🟢Quit Lunar → write names *and* current display IDs into its saved records → relaunch → verify the DDC wiring==. Writing while Lunar is quit means it can't overwrite the names on the way out; writing the IDs is what makes the relaunch wire DDC correctly the first time.

### Triggers

| When | Why |
|------|-----|
| Screen count transitions to 5 | new config |
| Any debounced screen change at 5 screens | catches 5 → 4 → 5 blips (count unchanged, IDs swapped) |
| Hammerspoon init | at login Lunar wires DDC from last session's IDs |
| Screens wake ([stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) sleep watcher → `layout.onWake()`) | checks are skipped while displays sleep |

==🟣While any display is asleep the script does nothing==: DDC reads to a sleeping monitor can hang, and a relaunched Lunar would push DDC to them too.

The script runs under Homebrew's `python3`, which on this Mac is x86_64 — it needs Rosetta. After the macOS 27 upgrade Rosetta was missing for ~15 minutes and every check silently failed to launch; a failed launch is now logged as `[layout.lunar] Error: couldn't launch …`.

## Position → Name Mapping

| Position | Lunar Name | How Detected |
|----------|-----------|--------------|
| bottom | ↓Bottom Center | Built-in Retina Display (anchor) |
| center | ⊙Middle Center | Center column, closest above built-in |
| top | ↑Top Center | Center column, furthest above built-in |
| left | ←Left | Left of built-in's X range |
| right | Right→ | Right of built-in's X range |

Screens whose center X falls within the built-in display's X range are "center column" (sorted by Y); others are sides (sorted by X).

## Lunar setting this relies on

`dcpMatchingIODisplayLocation = true` — ==🔵Advanced settings → "Match DDC port based on the IOKit position"==, Lunar's option for "commands are going to the wrong monitor". Enabled 2026-10-02. ==🔴Not sufficient on its own==: Lunar still wires DDC from its saved display IDs (problem 3), hence the checks above.

## Diagnostics

Lunar's CLI is the app binary with `@` (the `lunar` shim isn't installed); `--remote` talks to the running app only:

```bash
L="/Applications/Lunar.app/Contents/MacOS/Lunar"
"$L" @ --remote displays --json      # live UUID ↔ ID ↔ name
"$L" @ --remote edid <uuid>          # EDID read through that slider's DDC port
"$L" @ display-uuid <id>             # Lunar's own UUID derivation for an ID
```

Ground truth for which physical monitor is at which display: see `monitor_serials()` in [lunar-sync-names.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/lunar-sync-names.py). Lunar logs to the unified log under subsystem `fyi.lunar.Lunar` — in zsh call `/usr/bin/log`, since a bare `log` is a zsh builtin that silently prints nothing useful.

## Files

- [lunar-sync-names.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/lunar-sync-names.py) — the checks and the restart. Takes `{uuid: {name, id}}`. Exit 0 = Lunar restarted, 1 = nothing done (in sync, or displays asleep), 2 = error.
- [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) — `syncLunarNames()`, `scheduleLunarSync()`, and the triggers in the screen watcher, `M.init` and `M.onWake`. Output goes to the Hammerspoon console as `[layout.lunar] …`.
- [display-serials.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/display-serials.py) — read-only probe: each monitor's numeric serial (with its raw EDID bytes, e.g. Samsung's `"HYX0"`) and text serial, flagging monitors macOS can only tell apart by port. `--watch` logs every change, for plug-in tests.

## Manual Trigger

From the Hammerspoon console:

```lua
layout.syncLunarNames()
```

## How Lunar Stores Display Data

Lunar's preferences (`defaults read fyi.lunar.Lunar displays`) contain an array of JSON strings, one per display ever seen. Each entry has:

- `serial` — matches macOS display UUID (`hs.screen:getUUID()`)
- `name` — the display name shown in Lunar's UI
- `id` — the display ID at Lunar's last save; ==🔴used to wire DDC at the next launch== (problem 3)
- `edidName` — hardware EDID name (e.g., "LS37D70xE (2)")
- `brightness`, `contrast`, etc. — per-display settings, re-applied over DDC at launch

Over time, as macOS reassigns UUIDs, Lunar accumulates multiple entries for what is physically the same monitor. Each UUID gets its own entry with independent settings.

## Case studies

- ==🟢[2026-10-03-lunar-sliders-crossed-identical-samsungs.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/case-studies/2026-10-03-lunar-sliders-crossed-identical-samsungs.md)== — F010 dead for seven months after a code-prefix rename left `layout.lua` pointing at the old folder; then two Samsungs sharing a numeric serial, Lunar's launch-time wiring from saved IDs, and a post-upgrade Rosetta gap.
