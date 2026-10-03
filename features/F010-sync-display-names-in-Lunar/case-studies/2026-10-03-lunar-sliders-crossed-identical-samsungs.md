# Case: Lunar's sliders on the wrong monitors — a silent rename, identical Samsungs, and launch-time wiring (2026-10-03)

**Project:** [stepper](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper) × [F010-sync-display-names-in-Lunar](https://stepper.internal/features/F010-sync-display-names-in-Lunar/) × [F020-featurebase](https://topsight.internal/features/F020-featurebase/) × [F027-worldclass-code-debugging](https://fleet.internal/features/F027-worldclass-code-debugging/)

**The symptom:** After swapping the two portrait LGs for two Samsung LS37D70xE, [Lunar](https://lunar.fyi/)'s window was nonsense: the Right monitor's slider was labeled "⊙Middle Center", one entry said "No controls available", "LS37D70xE (2)" was really the Left, and the real Middle Center had no slider at all. The window-switch hotkeys worked fine.

==🟣The truth: four stacked causes. (1) [F010](https://stepper.internal/features/F010-sync-display-names-in-Lunar/), the automation built to fix exactly this, had been dead since 2026-03-13, when a folder rename gave it its code and didn't update the one path that loads it. (2) The two Samsungs are identical to macOS except for a serial string CoreGraphics doesn't expose, so macOS reshuffles their display IDs. (3) Lunar wires each slider to a DDC port at launch from the IDs it *saved last session*, and never re-checks. (4) After the macOS 27 upgrade, Rosetta was missing, so even the repaired F010 couldn't launch its Python.==

## Contents

- [GICV (retroactive)](#gicv-retroactive)
- [The rename that killed F010 — and why nothing caught it](#the-rename-that-killed-f010--and-why-nothing-caught-it)
- [Ground truth: which Samsung is which](#ground-truth-which-samsung-is-which)
- [Lunar's three ways to cross the sliders](#lunars-three-ways-to-cross-the-sliders)
- [The boot-time miss: Rosetta](#the-boot-time-miss-rosetta)
- [Wrong turns](#wrong-turns)
- [The fix](#the-fix)
- [Why Lunar doesn't catch this](#why-lunar-doesnt-catch-this)
- [Meta-lessons](#meta-lessons)
- [Tags](#tags)

## GICV (retroactive)

> **GOAL:** Every Lunar slider is named for, and drives, the monitor at that position — and stays that way across reboots and reconnect blips without manual fixes.
>
> **INVARIANT:** Hammerspoon's position detection and window-to-display hotkeys are untouched. Lunar is restarted only when something is actually wrong. No DDC traffic goes to sleeping displays.
>
> **COMPLETION:** Lunar shows ←Left / ⊙Middle Center / Right→ / ↑Top Center / ↓Bottom Center, and each slider's DDC port reaches the monitor macOS has at that position.
>
> **VERIFICATION:** For each display, the EDID read back through its slider's DDC port (`Lunar @ --remote edid <uuid>`) carries the same alphanumeric serial that IOKit reports for the framebuffer CoreDisplay assigns to that display. A deliberately crossed Lunar (saved IDs swapped) is detected and repaired by F010 on its own: `Crossed DDC … → Lunar restarted → DDC wiring verified` at 00:51:22.

## The rename that killed F010 — and why nothing caught it

| When | Commit | What |
|---|---|---|
| 2026-03-02 20:23 | `7ea5e96` | F010 added; [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) loads `../features/sync-display-names-in-Lunar/lunar-sync-names.py` |
| 2026-03-13 00:06 | `9453eee` | "Featurebase: add F010 code" — a Claude session `git mv`'d the folder to `F010-sync-display-names-in-Lunar`. ==🔴`layout.lua` not touched== |
| 2026-10-02 20:21 | — | Samsungs plugged in; F010 fires and fails: `can't open file '…/features/sync-display-names-in-Lunar/lunar-sync-names.py'` |

==🔴Seven months dead, with no visible sign.== The only evidence was one line in the Hammerspoon console per 5-screen transition, and nobody reads that console unless something is already being debugged. Meanwhile the old LG setup kept drifting, which is exactly what F010 existed to prevent.

**Why no check caught it:** at the time, the [featurebase skill](openfile:///Users/sara/.claude/skills/featurebase/SKILL.md) had no reference check at all. It has since gained one: [rename-feature.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/topsight/features/F020-featurebase/subfeatures/featurebase-skill/rename-feature.py) greps for stale references, and the promote-to-subfeature steps say to. ==🔴But neither covers this operation==:

- `rename-feature.py` handles slug renames of folders that already have a code (`{code}-{old}` → `{code}-{new}`). Giving an uncoded folder its code — what broke F010 — is still a hand-run `git mv`.
- A naive check would also be noisy here: the old name `sync-display-names-in-Lunar` is a **substring of the new one**, so `grep -r sync-display-names-in-Lunar` reports every *valid* `F010-sync-display-names-in-Lunar` reference too. The grep must be anchored on a path boundary (`/sync-display-names-in-Lunar/`).

**Other casualties?** A scan of every tracked file for `features/…` and `docs/research/…` targets that don't exist found ==🟢no other live breakage==. The remaining hits are historical do-done logs, `L005-...` placeholders, and links into other projects (`fleet.internal`, `topsight.internal`, `mas2.internal`).

## Ground truth: which Samsung is which

What macOS sees for the two Samsungs:

| | Left | Right |
|---|---|---|
| Vendor / product | SAM / 30976 | SAM / 30976 |
| Numeric EDID serial | 811096392 | 811096392 |
| EDID UUID | `4C2D0079-…-0104B5522F78` | same |
| **Alphanumeric serial** | ==🟢`HNTL300014`== | ==🟢`HNTL300013`== |

Samsung writes the same numeric serial into every unit; the unique ID is only in the EDID's alphanumeric serial string, which CoreGraphics doesn't expose. So macOS tells the pair apart by **port** alone, and its UUIDs and display IDs for them shuffle (both got new UUIDs at the macOS 27 reboot; the LGs, with unique serials, kept theirs).

The chain that recovers the truth, all read-only:

1. CoreDisplay's info dictionary (private, via `ctypes`) gives each display ID its framebuffer: `IODisplayLocation` → `dispext2`.
2. `ioreg -a -l -r -n dispext2 -d 2` gives that framebuffer's monitor: `AlphanumericSerialNumber = HNTL300014`.
3. `Lunar @ --remote edid <uuid>` ==🟢reads the EDID back through the DDC port Lunar wired to that slider== — the same port its brightness writes go to. No brightness change, no flicker.

If (2) and (3) disagree, the slider is crossed. This one comparison is the invariant the user cares about; names and IDs are only proxies for it.

## Lunar's three ways to cross the sliders

1. ==🔴Names on the wrong UUIDs== — the original F010 problem; Lunar keys names by UUID.
2. ==🔴Stale objects after a reconnect blip== — at 20:28 one monitor dropped and returned (5 → 4 → 5). macOS swapped the Samsungs' display IDs; the running Lunar kept its old UUID ↔ ID pairing. `lunar refresh-displays` rebuilt the DDC services and kept the stale pairing.
3. ==🔴Launch-time wiring from saved IDs== — even a fresh Lunar came up crossed. Six clean launches in a row made it look like a coin flip; the one crossed launch was the first after a stale session. ==🟢Reproduced deliberately==: with Lunar quit, swap the two Samsungs' saved `id` in its prefs → launch → crossed; launch again (Lunar has now re-saved real IDs) → correct. A launch after macOS swapped IDs therefore comes up crossed **with correct live IDs**, invisible to any ID check.

Lunar's "Match DDC port based on the IOKit position" setting (`dcpMatchingIODisplayLocation`) was enabled along the way. ==🔵With it on, the HDMI LG was wired correctly on every launch== (before, it had been handed a Samsung's port — though the reboot also moved it to another port, so the credit isn't certain) ==🔴but the Samsung pair still followed the saved IDs==.

## The boot-time miss: Rosetta

The macOS 27 upgrade rebooted mid-fix. After boot, Lunar was crossed again, and F010 — now with a working path — produced ==🔴no output at all== across 17 screen events. Ruled out first: GC of an unreferenced `hs.task` (tested: callbacks still fire after forced `collectgarbage()`), and the code path (the identical path replayed later worked).

The cause: `/usr/local/bin/python3` is Intel Homebrew, an ==🔴x86_64 binary== on this M1 Max. Rosetta wasn't installed after the upgrade until `softwareupdate --install-rosetta` ran at 00:20:14; until then `hs.task:start()` failed and no callback ever fired. ==🔴This dependency was introduced during this very fix==: the old F010 went through `bash` + `PATH`, which resolved to Xcode's native Python. Homebrew Python was kept to honor the "never system python" rule; `:start()` failures are now logged.

## Wrong turns

- ==🔴DDC fingerprinting as proof.== "Middle Center's port reports input `0x0F` and VCP version 0, like the Samsung" was presented as proof, but the two LGs are different models and could differ the same way. ==🟢The EDID read-back settled it==: Middle Center → `HNTL300013`.
- ==🔴"A restart fixes it."== It fixed Lunar's live IDs, not its DDC wiring — that took the saved-ID mechanism.
- ==🔴"The IOKit-position setting is the fix."== Necessary for the HDMI LG, not sufficient for the Samsungs.
- ==🔴Empty unified-log queries.== In the zsh-based Bash tool, `log` is a shell builtin; `log show … 2>/dev/null` silently returns nothing. Several "Lunar logs nothing" readings were void until `/usr/bin/log` was used.
- ==🔵Refuted cleanly:== GC of `hs.task`, an `arm-io@<addr>` path-format mismatch, Lunar's version (6.11.0 for every launch), and the `defaults import` → relaunch timing.
- ==🔴Verification hung==: a check run after the displays slept (00:52:51) blocked on an EDID read of a sleeping monitor — which became the sleep guard.

## The fix

All in [F010](https://stepper.internal/features/F010-sync-display-names-in-Lunar/) — [lunar-sync-names.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/lunar-sync-names.py) and [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua):

- Path fixed; Hammerspoon passes `{uuid: {name, id}}`.
- Three checks: names, live UUID ↔ ID pairing, ==🟢DDC read-back vs ground truth==. Problems are re-checked after 3s before acting.
- Restart = quit Lunar → write names **and current IDs** into its saved records → relaunch → verify. Writing the IDs makes the first relaunch wire correctly.
- Triggers: transition to 5 screens, any 5 → 5 screen change (blips), Hammerspoon init (login), screens wake. ==🟣Skips entirely while any display sleeps.==
- Launch failures and crashes are loud: `:start()` checked; uncaught exceptions exit 2, not 1 ("nothing to do").

## Why Lunar doesn't catch this

Lunar does have to solve the hard half: there's no public API linking a display to its DDC port on Apple Silicon, so it matches by EDID heuristics or IOKit position. What it skips is the cheap half — ==🔵re-checking after launch==. It wires from saved IDs, never compares the result with what's on each port, and `refresh-displays` doesn't reconcile stale objects. Same-model monitors are common; this bites when the model also writes a **constant numeric serial** (as these Samsungs do), which is why most multi-monitor Lunar users never see it. The saved-ID reproduction above would make a precise upstream bug report.

## Meta-lessons

### 1. ==🔴A rename must carry its references — by default, not by memory==

Every folder move is a potential dangling path. The check belongs *in the tool that moves*, run every time: grep for the old path **anchored on segment boundaries** (old names can be substrings of new ones), and fail the operation when live code still points at the old location. Code-prefix adoption, slug renames and subfeature promotion should all go through one scripted path.

### 2. ==🔴Background automations must fail loudly==

F010 "worked" for seven months because its failure went only to a console nobody reads. [F027 §3](https://fleet.internal/features/F027-worldclass-code-debugging/#3-observability-survives-the-fix): if a feature runs unattended, its broken state must be visible without looking for it — a missing dependency at load time, a task that can't launch.

### 3. ==🔵Verify the invariant, not its proxies==

Names correct, IDs correct — sliders still crossed. ==🟢Only the end-to-end read-back (slider's port → monitor serial) caught launch-time crossing.== When a proxy check passes, ask what the user would actually see.

### 4. ==🔵Turn a coin flip into a mechanism by forcing it==

"Sometimes crossed" after six clean launches looked random. Forcing the suspected precondition (swapped saved IDs) reproduced it on demand and pointed straight at the fix. [F027 §1](https://fleet.internal/features/F027-worldclass-code-debugging/#1-test-gauntlets-not-assumptions).

### 5. ==🔵Check the instrument before trusting an empty result==

An empty log query (zsh builtin) and a missing callback (Rosetta) both read as "nothing happened". ==🟢Calibrate the instrument on a known-positive case first== — the log query against the known-good 00:30 run is what exposed the builtin.

## Tags

- lunar, ddc, dcp, iavservice, edid, alphanumeric-serial, coredisplay, iodisplaylocation, identical-monitors, samsung-ls37d70xe, hammerspoon, rosetta, macos-27, featurebase-rename
- dangling-path — a code-prefix rename broke a relative path in Lua; old name is a substring of the new one
- launch-time wiring — Lunar wires DDC from saved display IDs; forced by swapping saved IDs
- ground truth — CoreDisplay `IODisplayLocation` → `ioreg` `AlphanumericSerialNumber` vs `Lunar @ --remote edid`
- memory: [lunar_ddc_wiring.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/lunar_ddc_wiring.md), [homebrew_python_rosetta.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/homebrew_python_rosetta.md), [zsh_log_builtin.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/zsh_log_builtin.md)
- related: [F027 §0](https://fleet.internal/features/F027-worldclass-code-debugging/#0-the-first-bug-you-find-is-the-surface-bug), [F027 §3](https://fleet.internal/features/F027-worldclass-code-debugging/#3-observability-survives-the-fix), [F020 featurebase skill](https://topsight.internal/features/F020-featurebase/subfeatures/featurebase-skill/)
