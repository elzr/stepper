# A Bear note walked to the bottom of the screen: macOS drops a hotkey's release while Hammerspoon is busy

**Date**: 2026-10-09
**Status**: ==🟢Fixed==. Stepper's key repeat now asks the HID system itself whether the key is still down ([stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) `bindWithRepeat`, [inputprobe.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/inputprobe.swift) `hold`)
**Follows**: [2026-10-07: runaway hotkey repeat after a lost key-up](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat-after-lost-key-up.md). Probe scripts: [2026-10-09-lost-key-up-walked-note-down/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/)

## Contents

- [Symptom](#symptom)
- [What the logs caught](#what-the-logs-caught)
- [Timeline](#timeline)
- [The cause: a busy main thread loses the release](#the-cause-a-busy-main-thread-loses-the-release)
- [Why the 10-07 guard didn't stop it](#why-the-10-07-guard-didnt-stop-it)
- [Who is to blame](#who-is-to-blame)
- [The fix](#the-fix)
- [Verification](#verification)
- [Side findings](#side-findings)
- [Next time](#next-time)

## Symptom

The w36tlog Bear note on the right Samsung slid down on its own until only ==🔴66 px of its title bar showed at the bottom edge== (y from -1220 to 627; the screen ends at 693). The user recognized "the stuck bug" at once. It was the first incident since the [10-07 guard](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat-after-lost-key-up.md) went in, so the open question was whether its forensics had caught it.

## What the logs caught

They had. From [data/lost-key-ups.log](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/lost-key-ups.log):

```
2026-10-09 14:45:08  [stepper] lost key-up: pagedown in Bear, repeat stopped after 5.0s (held over 5s) · secure input off · HID holds: nothing
2026-10-09 14:45:08  [stepper] taps that could drop a key-up: BetterTouchTool hid · SiriNCService session · Hyperkey session · Monologue annotated · Siri session | since load: Hammerspoon session on 2→3, ViewBridgeAuxiliary session listen +up 0→1
```

- **The key**: plain fn+↓ (Hammerspoon's `pagedown`, move down) on the note.
- **The stop**: the guard's 5 s cap, about 140 steps at 30 Hz. ==🔴The modifier check never fired==, the first sign that something was off.
- **The keyboard**: `HID holds: nothing`. The keyboard layer had released the key, so the key-up existed and was lost on its way to Hammerspoon.
- **Not a wake**: the last full wake was at 12:33, the screen was unlocked at 14:25 after a 2-minute lock, and the user had been working all along. The line has no "min after wake/unlock" because a reload at 14:40 had reset inputprobe's memory of them.

## Timeline

Reconstructed from the console, the [1-minute layout backups](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/layout-backups/) (copied before they rotated) and the system log:

| Time | Event | Source |
|---|---|---|
| 14:43:59 | Note at x=4493, y=-1601 | `layout-1m-06-c5.json` |
| 14:44:59 → 14:45:01 | ==🟣The per-minute layout save runs 2 s late==; the saves before and after land on :59. Hammerspoon's main thread is busy | console |
| ~14:45:01 | fn+↓ press handled; the repeat starts | the report (5.0 s before the stop) |
| 14:45:01 | Note at x=4277, y=-1220 | `layout-1m-07-c5.json` |
| ~14:45:06 | 5 s cap stops the repeat | report |
| 14:45:08 | `lost key-up` report written | `lost-key-ups.log` |
| 14:45:09 | hyper+F (featurebase): after the stop, not what stopped it | console |
| 14:45:59 | Note at x=4283, y=627, 66 px visible | `layout-1m-08-c5.json` |

The note was moved back to its 14:45:01 frame afterwards.

## The cause: a busy main thread loses the release

Both incidents began while Hammerspoon was busy at the press: today the late layout save, and on 10-07 Bear deactivating in the same second fn went down. So the probes pressed keys from outside Hammerspoon while its main thread was blocked. [keypost.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/keypost.swift) is a small helper launched through `hs.task`, so Hammerspoon's Accessibility grant covers it. It posts F20 at the HID tap with a HID-state source, which reaches the HID key state the way a real keyboard does.

**[busy-release-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/busy-release-probe.lua)**: the main thread was frozen 2–4 s while F20 went down and up. The press and the release were both lost, and presses kept failing for a while after the freeze. A real ⌘⇥ the user pressed during the first freeze went dead too (see [Side findings](#side-findings)).

**[slow-callback-release-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/slow-callback-release-probe.lua)**: the incident's shape. The press arrives, and its callback keeps the main thread busy for 2 s, as a slow AX move of a Bear window would.

| Trial | Hammerspoon | Release order | Press | Release |
|---|---|---|---|---|
| K1 | idle | — | ✓ | ✓ |
| K2 | busy | no modifier | ✓ | ✓ |
| K3 | busy | key up, then ctrl up | ✓ | ✓ |
| K4 | busy | ==🔴ctrl up, then key up== | ✓ | ==🔴lost== |
| K5 | idle | ctrl+F20 again | ==🔴swallowed== | ✓ (closes K4's press) |

**[tap-pause-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/tap-pause-probe.lua)** repeated K4 four times. Two runs had Hammerspoon's four event taps running and two had them paused, found by walking every reachable Lua value. ==🟢All four lost the release==, so Hammerspoon's own taps are not the mechanism. (A first run gave each trial its own key; ctrl+F17–F19 never reached Hammerspoon at all, so every trial now uses ctrl+F20.)

**[idle-control-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/idle-control-probe.lua)**: with Hammerspoon idle, the modifier-first release arrived both times, as it did in [10-07's T3](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/release-probe.lua). In its busy trial the timing slipped: the key came up before the callback started blocking, and the release arrived too.

| Hammerspoon when the key comes up | Release order | Release delivered |
|---|---|---|
| busy | modifier first, then key | ==🔴lost, 5 of 5== |
| busy | key first, or no modifier | ✓ 2 of 2 |
| idle | modifier first | ✓ 3 of 3 |

So ==🔴when the modifier comes up before the key while Hammerspoon's main thread is busy, macOS never delivers that hotkey's release==. Nothing reports the loss. macOS then still counts the hotkey as down: the next press of the same combo is swallowed, and its key-up delivers the old release. What happens inside the WindowServer and HIToolbox can't be observed from here, so this is the empirical rule.

For fn+↓, fn plays ctrl's part: releasing fn first makes the keyboard filter synthesize the PageDown key-up at the fn release (10-07 case study). This was not probed with a synthetic fn, which could have triggered the Globe key or a dictation app.

## Why the 10-07 guard didn't stop it

The guard required every modifier held at the press to still be held. ==🔴While the main thread is busy, `hs.eventtap.checkKeyboardModifiers()` reports the old state==. In K3, ctrl still read as held 1.8 s after its release; in K4 it read as held right after the busy call and had cleared within 2.3 s. So after a release lost this way, fn can read as held for as long as the stale state lasts, and only the 5 s cap was left. The HID system knew better all along: `HID holds: nothing`.

## Who is to blame

- **macOS** drops the release, silently. That is the actual loss.
- **Stepper** sets it off. It does slow synchronous work on Hammerspoon's only thread: the per-minute layout save reads every window through AX, and moves call into Bear and Chrome, whose AX can be slow. And its guard trusted the two signals that fail at exactly that moment: the release and the modifier state.
- **Hammerspoon** sets the stage. One thread runs everything, hotkeys included, and Lua has no way to read the keyboard's real key state.
- **Not Hammerspoon's event taps** (pausing them changed nothing). Nothing points at BetterTouchTool, Hyperkey, Siri or Monologue either: the loss happened every time Hammerspoon was busy and never otherwise. Their taps were present in every probe, though, so they aren't strictly excluded.

## The fix

[stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) `bindWithRepeat`, with [inputprobe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/inputprobe.lua) and [inputprobe.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/inputprobe.swift):

1. ==🟢Each press starts `inputprobe hold <keycode>`==. It polls `CGEventSource.keyState(.hidSystemState)` every 10 ms and exits when the HID system lets go. That view comes before every tap and hotkey route and doesn't lag. A tick now stops on the first of: keyboard let go, a press-time modifier up, or 5 s. The release callback terminates the watcher.
2. **A lost key-up is reported only once the keyboard has really let go.** A long hold past the cap is not a loss. ==🟢Then a synthetic key-up closes the stuck hotkey==, so the next press isn't swallowed.
3. **The repeat has an owner.** A release now stops only its own key's repeat, so the synthetic key-up can't cut short a hold on another key. Before, any binding's release stopped whichever repeat was running.
4. **Forensics.** The report adds `modifiers at press …, at stop …` and `main thread stalled Xs, until Ys before/after the press`, from a 0.25 s lag ticker that keeps two minutes of stalls. Wake and unlock times now survive reloads (`hs.settings`). `_G._stepper.inputprobe.recentHolds()` lists what the last 20 watchers saw.

==🔵Cost==: one short-lived process per stepper press, running only while the key is down. No console output unless a key-up is lost.

Dropped on the way: an earlier idea, no repeat when fn is already up at the press. The hold watcher covers that case without trusting the lagging modifier state.

## Verification

**HID state at the press** ([hid-at-press-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/hid-at-press-probe.lua)): in 5 of 5 keypost presses, the HID system already held F20 when the press callback ran. The watcher reported each release 652–667 ms later, together with the hotkey release.

**Regression test** ([repeat-guard-test.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/repeat-guard-test.lua), which supersedes [10-07's](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/repeat-guard-test.lua), whose Hammerspoon-posted F20 never reaches the HID key state):

| Scenario | Expected | Observed |
|---|---|---|
| S1 0.7 s hold, fn held | repeats, stops at the key-up | ✓ in 6 isolated runs; 2 full-run anomalies (see below) |
| S2 K4 for real through `bindWithRepeat` | ==🟢one step==, report, synthetic key-up | ✓ `… repeat stopped after 2.3s (keyboard let go) · modifiers at press ctrl, at stop none · main thread stalled 1.9s, until 2.0s after the press · HID holds: nothing` |
| S3 next ctrl+F20 press | works (S2 closed) | ✓ not swallowed |
| S4 8 s hold | stops at 5 s, no report | ✓ |
| S5 fn released mid-hold | stops within a tick, no report | ✓ |

S1 misbehaved twice in full runs. The first time, the user pressed stepper keys during it, and a new stepper press stops the repeat by design. The second time, its release and its watcher both stayed silent and the faked fn kept it going until the test switched to real modifiers. [s1-repro-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down/s1-repro-probe.lua) didn't reproduce it in 6 runs. With a real key, the fn check would catch that case, since fn really comes up.

**Real keys**: ==🟢after the reload, 20 real fn+arrow presses all tracked correctly==. 18 kept their watcher alive until the hotkey release; 2 quick taps had the watcher see the key-up 21–41 ms in. Had the HID state missed fn-remapped keys, every watcher would have exited at once and no hold would repeat. The user held fn+→ and then fn+←: "repeating normally".

## Side findings

- ==🔴A frozen Hammerspoon kills other keys too.== During the first probe's freeze, a real ⌘⇥ went dead. cmdtabwatch judged it: "the key reached the HID tap but not the end of the session taps: a filtering tap in between took it", since Hammerspoon's keyDown/flagsChanged filter taps hold every key while its main thread is stuck. That entry in `data/cmd-tab-watch.jsonl` now carries a `note`. For the AltTab trial (fleet F040): a dead ⌘⇥ during a Hammerspoon stall isn't AltTab's fault.
- **Hyperkey's tap was OFF** at 14:56–14:59 (enabled at 14:45:08; hyper+F/P worked at 14:45:09/15) and back ON by 15:14 without intervention.
- **An `hs` CLI call hung again** while Hammerspoon's main thread sat idle, as on 2026-10-08. This time it was a call that bound a hotkey and started an `hs.task`, with no AX involved. It was cleared the safe way: a deferred `hs.relaunch()`, then `kill` of the stuck client. The console from before 15:36 was saved first.
- **Noise ruled out**: WindowServer's "Clearing datagram buffer for cid …" lines, all day, belong to Monologue (cid 0x108fa3), Bear's widget extension and Pixelmator's thumbnail extension, not Hammerspoon. `CGGetEventTapList` latencies are useless (min = avg = max, in seconds).

## Next time

A `[stepper] lost key-up` line now tells its own story:

- ==🟣`main thread stalled …` near the press== → this mechanism. Look at what Hammerspoon was doing then: a slow AX app, a restore (the layout save no longer stalls it, see below).
- `main thread on time` → something else lost it; the tap list on the second line is where to look.
- `modifiers at press none` on an fn+arrow key → the press itself was handled late.

The trigger is still there: stepper's slow work on the main thread. The fix makes a lost release harmless (one step, then closed); it doesn't make releases stop getting lost. If they keep turning up, the next step is to shorten the stalls, starting with the layout save's AX sweep. Review due 2026-11-07 with the other lost key-up forensics.

==🟢Done the same evening==: [layout saves now read the windows in a helper process](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/changelog/2026-10-09-layout-saves-off-the-main-thread.md), 6–12 ms of main thread per save, and screenmemory no longer takes 8.7 s to load at every reload. So a stall in a report after 2026-10-09 19:05 points at something other than the save.
