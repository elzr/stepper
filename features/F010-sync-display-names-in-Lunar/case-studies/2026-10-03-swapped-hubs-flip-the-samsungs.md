# Case: swapped hub cables turn the Samsungs upside down, and the layout follows the virtual desktop instead of the monitors (2026-10-03)

**Project:** [stepper](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper) × [F010-sync-display-names-in-Lunar](https://stepper.internal/features/F010-sync-display-names-in-Lunar/) × [L006-layout-restore-of-windows-in-screens](https://stepper.internal/features/L006-layout-restore-of-windows-in-screens/) × [F027-worldclass-code-debugging](https://fleet.internal/features/F027-worldclass-code-debugging/)

**The symptom:** At 20:04 the MacBook went back onto the quad-32 desk with the two OWC hubs' cables in each other's Mac ports (the cables are marked, so the swap was noticed). Both 37" Samsungs came up ==🔴upside down, menu bar at the bottom==. Swapping the cables back at 20:05 fixed the picture, but afterwards ==🔴the windows that belong on the side screens were not there==.

==🟣The truth: three stacked causes. (1) macOS cannot tell the two Samsungs apart, so it tags each with a UUID that follows the connection slot it enumerates on; the saved rotation and position ride on that UUID, and the cable swap handed each panel the other's. (2) The arrangement guard saw the problem 4 s after the transition and asked Lunar to rotate both panels back, twice; Lunar answered `rotation: N` and changed nothing, because its rotation is a cached number that already equalled the request. (3) The swap-back was a 5 → 1 → 5 blip to [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua), which restores nothing on a same-count change, while macOS had pushed every window onto the built-in display; 60 s later the autosave recorded those positions as the layout.==

## Contents

- [GICV (retroactive)](#gicv-retroactive)
- [Timeline](#timeline)
- [Why the panels flipped](#why-the-panels-flipped)
- [Why the guard did not fix it](#why-the-guard-did-not-fix-it)
- [Why the windows came back wrong](#why-the-windows-came-back-wrong)
- [What is preserved](#what-is-preserved)
- [Proposed fixes (not applied)](#proposed-fixes-not-applied)
- [Wrong turns](#wrong-turns)
- [Meta-lessons](#meta-lessons)
- [Tags](#tags)

## GICV (retroactive)

> **GOAL:** Plugging the hubs into either Mac port gives the same desk: both Samsungs portrait on their sides, windows on the screens they were saved on.
>
> **INVARIANT:** No rotation or DDC traffic to sleeping displays. macOS's own arrangement store is left to macOS. The layout file is only written from a state that has been checked against the saved one.
>
> **COMPLETION:** After a swap, the guard rotates and re-places both panels on its own, and the layout restore puts the side windows back without a hand.
>
> **VERIFICATION:** WindowServer's `setting rotation angle` lines show the guard's rotation landing; the 1-minute layout ring never records a window on `bottom` that the saved layout had on `left` or `right` within five minutes of a screen change.

## Timeline

Sources: WindowServer (`/usr/bin/log show --predicate 'process == "WindowServer"'`, the `SkyLight:display` lines), the Hammerspoon console (`~/bin/hs-console.sh 0`, which kept the whole evening), Lunar's process log, file mtimes. The layout log ring only keeps ten minutes, so the console was the only record of what layout.lua did.

| Time | What | Source |
|---|---|---|
| 20:03:21 | Last autosave of only-43 (c2), 16 windows | console |
| 20:04:10 | The 43" goes out → c1 "native"; 20:04:15 transition restores `window-layout-1.json` (8 moved, 19 unmatched, retry polling starts) | console |
| 20:04:30–33 | Hub L in: center LG, then the first Samsung → twin key `7BAA`, rotation 0 → 270 at (-2160,-2891) | WindowServer |
| 20:04:35 | Both out again (a blip) | WindowServer |
| 20:04:39–42 | All four in. LGs take keys `DFF0`/`CB72` ("Adjusting" their UUIDs onto them); the Samsungs take `BF53` (rotation 90 at 3840,-3003) and `7BAA` (rotation 270 at -2160,-2891). "Detected twin display" | WindowServer |
| 20:04:56–58 | Transition c1 → c5; restore from `window-layout-5.json`: 4 moved. `_mem NOW` and `w40days` go to "LS37D70xE (2)" = virtual left = ==🔴physical right==; `w40thoughts` to "(1)" = physical left | console |
| 20:05:00 | Guard: `fixing (transition): left HNTL300014 rotation 90, want 270; right HNTL300013 rotation 270, want 90` → Lunar rotate left, 20:05:02 right | console |
| 20:05:03 | F010 Lunar sync: "No changes needed" (names and DDC match macOS's virtual sides, so nothing was wrong by its invariant) | console |
| 20:05:20 | Guard: `attempt 1 failed (rotation didn't land …)`, 20:05:25–27 attempt 2 | console; ==🔴no `setting rotation angle` in WindowServer between 20:04:42 and 20:05:29== |
| 20:05:29 | User pulls both hubs: four displays out within 0.5 s; macOS moves every window to the built-in | WindowServer |
| 20:05:34–36 | Hubs back in their usual ports: Samsungs take `DFF0` (rotation 90 at 3840,-3147) and `CB72` (rotation 270 at -2160,-2757), "Detected match in persistent store" → ==🟢correct picture, by macOS alone, 7 s after the re-plug== | WindowServer |
| 20:05:33 / 20:05:52 | Console: screens 5 → 1 (stability wait), then 1 → 5: `count == activeCount` → no transition, no restore, only Lunar sync + guard | console |
| 20:05:52–54 | Guard gives up on the old episode ("rotation didn't land for HNTL300013"), re-checks: "ok (screens)" and learns the new origins into `display-guard.json` | console, mtime 20:05 |
| 20:05:57 | Autosave: `_mem NOW@bottom, w40days@bottom, w40thoughts@center`; only Telegram FAMILIA is still protected ("kept at right") | console |

## Why the panels flipped

For every external display WindowServer logs its EDID identity and a slot: `v: 0x00004c2d m: 0x00007900 s: 0x30585948 … asn: <private> p: 0x0c80e010`. It reads the alphanumeric serial (`asn`) but does not use it: the next line is `Twins: found with optional key …`, and the key decides which UUID the panel gets. Four keys have been seen, one per slot `p`:

| slot `p` | key | UUID | saved rotation, side |
|---|---|---|---|
| `0x0c80d000` | `DFF0-467667D25473` | `FDE46DA5` | 90, right |
| `0x0c80d010` | `CB72-E60014E0210A` | `ED4D9D3B` | 270, left |
| `0x0c80e000` | `BF53-413C0DE0DF9F` | `86D1A557` | 90, right |
| `0x0c80e010` | `7BAA-01ED1636D84C` | `FD24B45E` | 270, left |

The `d`/`e` half depends on which pipes are free when a Samsung enumerates: at 20:04:39 the LGs took `d000`/`d010` first and the Samsungs landed in `e`; at 20:05:34 the Samsungs came first and took `d`. The LGs are "Adjusted" onto whatever is left each time, which is harmless for them because macOS re-maps a unique-serial display's UUID to its new key. The `000`/`010` half followed the Mac port: ==🟢in all eight reconnects today with the hubs in their usual ports (00:06, 09:38 twice, 11:14, 12:26, 13:23, 15:51, 20:05) the right panel got a `…000` key and the left a `…010` key==; in the one swapped reconnect (20:04) ==🔴the physical right got `7BAA`/`e010` and the physical left got `BF53`/`e000`==.

macOS then did exactly what it is built to do: "Detected match in persistent store" for the UUID pair {`FD24B45E`, `86D1A557`} and applied that pair's saved arrangement. The panel mounted for 90° received 270° and the left-hand origin, the panel mounted for 270° received 90° and the right-hand origin. 180° apart reads as upside down, and each panel showed the other side of the desktop, which is why "left" windows appeared on the right-hand glass.

Two corrections to the [README](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/README.md#arrangement-guard) and the project memory: the key is a ==🔵connection slot, not (hub, DP stream slot)==, since moving the hubs between ports moved the keys with the ports; and the four UUIDs are not "two per monitor" but one per slot, so which panel wears which UUID is a property of the cabling.

## Why the guard did not fix it

[displayguard.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/displayguard.lua) did what it was built to do: it identified the panels by text serial 4 s after the transition and sent `Lunar @ --remote displays <uuid> rotation N` for each. Lunar replied `rotation: 270` and `rotation: 90` (no "didn't take rotation" retries were logged) and WindowServer applied nothing. Three facts say why:

- Lunar's saved records (`defaults export fyi.lunar.Lunar`) for the two UUIDs active at 20:04 already held the requested values: `FD24B45E` → `rotation: 90`, `86D1A557` → `rotation: 270`. ==🔴Setting a Lunar property to the value it already holds is a no-op==; Lunar never called MonitorPanel.
- Right now, with macOS at 90/270, `Lunar @ --remote displays <uuid> rotation` prints `rotation: 0` for both `ED4D9D3B` and `FDE46DA5`. ==🔵Lunar's rotation is its own last-set number, not the display's state.==
- The fixes that worked earlier today (13:48, 15:51, 00:08) all changed Lunar's stored value.

So the rotation step fails exactly when a cable swap puts a panel on a UUID whose Lunar record already holds the wanted rotation, which is the case after the first fix of each UUID. The guard's verification caught it (`rotation didn't land`), but the retry resent the same command. The swap-back ended the episode before anything else could happen.

## Why the windows came back wrong

1. ==🔵Positions are virtual.== `layout.lua` saves `screenPosition` from screen frames ([screenswitch.buildScreenMap](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenswitch.lua): left of the built-in's X range is "left"). At 20:04:58 "left" was `FD24B45E` at x = -2160, physically the right monitor. The restore was correct in desktop coordinates and wrong on the glass.
2. ==🔴No restore on a same-count change.== The swap-back went 5 → 1 → 5 inside the debounce and stability windows, so `onScreenChange` took the `count == activeCount` branch, which only re-runs the Lunar sync and the guard. macOS had moved every window to the built-in at 20:05:29 and did not move them back when the displays returned.
3. ==🔴The autosave 60 s after the transition made it permanent.== `startPeriodicSave` fired at 20:05:57. Position protection only covered entries the 20:04:58 restore had not verified: Telegram FAMILIA was still protected and "kept at right"; the three Bear windows had been verified by exact-title match, so they were saved on `bottom` and `center`. Every restore since then has placed them there.

The side windows were not lost. They were saved on the wrong screens. The 20:14 ring snapshot has 16 windows with one on each side; the 17:21 snapshot from before the incident had 9 windows with three on the left and two on the right.

## What is preserved

- The last pre-incident 5-screen layout (17:21) was about to be overwritten by the 10-minute ring around 21:45; it is copied to ==🟢[layout-pre-hubswap-20261003-1721-c5.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/layout-backups/layout-pre-hubswap-20261003-1721-c5.json)==. From the console: `layout.restoreFromJSON(io.open("<path>"):read("*a"), "pre-hubswap")`.
- [display-guard.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/display-guard.json) now holds the origins macOS applied at 20:05:36 for pair {`ED4D9D3B`, `FDE46DA5`}: left (-2160,-2757), right (3840,-3147). That is the guard learning, as designed; the README's (-2891)/(-3003) belong to the pair {`FD24B45E`, `86D1A557`}.

## Proposed fixes (not applied)

==🟢Follow-up 2026-10-04==: the Lunar nudge and the layout changes below went in that evening; the nudge did not help (Lunar's rotation acts on a display object cached before the re-enumeration), and the guard now rotates through MonitorPanel directly — see [2026-10-04-lunar-rotation-caches-go-stale.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/case-studies/2026-10-04-lunar-rotation-caches-go-stale.md).

Guard, [displayguard.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/displayguard.lua):

- ==🟢Make the rotation step idempotence-proof.== Read Lunar's believed rotation first (`displays <uuid> rotation`); if it equals the target while macOS differs, nudge: set macOS's current rotation (a no-op on screen that updates Lunar's cache), then the target. Or, when the first command has not landed after ~5 s, resend through an intermediate value instead of repeating it.
- Longer term, rotate without Lunar: MonitorPanel.framework is what Lunar and System Settings call. A small Swift or ObjC helper would remove the dependency on Lunar's state; PyObjC is not installed in either python.
- ==🔴Switch `PYTHON` to `/opt/homebrew/bin/python3`== here and in `layout.lua`. Both scripts are stdlib + ctypes and `display-serials.py` ran natively in this session. [F040](https://fleet.internal/features/F040-uptodate-infrastructure/) deletes `/usr/local/bin/python3` on 2026-11-02, after which both keepers would fail with a line only the console sees.

Layout, [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua):

- On `count == activeCount` after a debounced change, arm protection and run `restoreIfDrifted("screens")` after a short settle, as `onWake` does.
- Hold the periodic autosave for a couple of minutes after any screen change, or until a drift check has run.
- Treat a restore whose *screen* match was `fallback` or `resolution` as unverified and keep the entry protected; today only an `index-fallback` *window* match keeps protection.
- Optional: a longer stability delay for transitions to lower counts, since re-cabling takes tens of seconds (the c1 restore at 20:04:15 moved 8 windows for nothing).

Docs: the README's "Arrangement guard" paragraph and [project_display_configs.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/project_display_configs.md) should say connection slot rather than (hub, slot).

What port-independence can mean here: macOS will keep saving whichever arrangement the current UUID pair ends up in, so after a swap and a fix the two variants ping-pong on later reconnects. ==🟣With the guard reliable, that is a few seconds of upside-down after each swap, which is the best software can do==. Making macOS itself indifferent to the port needs the two panels to differ in EDID, for example an in-line DisplayPort EDID emulator programmed with a different serial on one of them.

## Wrong turns

- ==🔴Empty log queries, again.== Bare `log` is zsh's builtin in the Bash tool; `/usr/bin/log` found everything ([zsh_log_builtin.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/zsh_log_builtin.md)).
- `hs` on the PATH is Node's http-server and `osascript` is refused (AppleScript is off in Hammerspoon). The CLI is `/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs`, as Stepper's [CLAUDE.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/CLAUDE.md) and `~/bin/hs-console.sh` already say. Reading that file first would have saved the detour.
- `Lunar[14123]` starting at 20:05:00 looked like an F010 relaunch. It was the guard's own CLI call: `Lunar @` runs the app binary as a command-line client.
- The first model, "the key is (hub, DP stream slot)", predicted no flip from swapping the hubs between ports. The swap is what refuted it.

## Meta-lessons

1. ==🔴A "set" that reports success is not an effect.== The guard already verifies through WindowServer; when that verification fails, the retry must change the input, not resend it. [F027 §1](https://fleet.internal/features/F027-worldclass-code-debugging/#1-test-gauntlets-not-assumptions).
2. ==🔵Two keepers, one truth.== The guard knows the monitors by serial; the layout layer trusts macOS's left/right. Windows should not be moved onto the Samsungs until the guard has said the sides are right.
3. ==🔵A same-count screen change is a reconfiguration too.== Any path that can leave macOS-shuffled windows in place must run the drift check before the next save.
4. ==🔴The autosave is the destructive step.== Everything else today was recoverable; the save at 20:05:57 cemented it. After a screen event, protection should be lifted by verification, not by a restore attempt. [F027 §3](https://fleet.internal/features/F027-worldclass-code-debugging/#3-observability-survives-the-fix).

## Tags

- samsung-ls37d70xe, twin-display, windowserver-skylight, connection-slot, uuid-map, lunar-rotation-noop, monitorpanel, displayguard, layout-restore, same-count-blip, autosave, position-protection, owc-hub, hammerspoon
- connection slot: WindowServer `p: 0x0c80[de]0[01]0` → `Twins: found with optional key` → UUID; the key follows the Mac port, not the hub or the panel
- Lunar `rotation` is a cached last-set value; equal-value sets are no-ops (reads 0 while macOS shows 90/270)
- related: [2026-10-03-lunar-sliders-crossed-identical-samsungs.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/case-studies/2026-10-03-lunar-sliders-crossed-identical-samsungs.md), [display_rotation_apple_silicon.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/display_rotation_apple_silicon.md), [L006 README](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens/README.md), [macos-display-configs.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/macos-display-configs.py), [display-serials.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/display-serials.py)
