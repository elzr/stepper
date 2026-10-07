# Windows walking to the screen edge: Hammerspoon's hotkey repeat outlived a lost key-up

**Date**: 2026-10-07
**Status**: ==🟢Fixed== — stepper runs its own guarded key repeat in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) (`bindWithRepeat`)
**Seen before**: rarely, "I recognize the bug" — never diagnosed until now

## Contents

- [Symptom](#symptom)
- [Timeline](#timeline)
- [Mechanism: one global repeat timer](#mechanism-one-global-repeat-timer)
- [What stopped it](#what-stopped-it)
- [Where the key-up went](#where-the-key-up-went)
- [The fix](#the-fix)
- [Verification](#verification)
- [Next time](#next-time)
- [Appendix: harness notes](#appendix-harness-notes)

## Symptom

Back at the computer after a break, ==🔴every window that took focus started stepping right on its own== until it hit the right edge of the right Samsung (LS37D70xE, HNTL300013). Four windows ended at `x=5960` — 40 px visible, the most macOS lets a window be pushed off-screen — and a fifth stopped part-way at `x=5835`. Sizes were untouched; only positions changed. It stopped by itself once a feature session was opened from Raycast.

## Timeline

Reconstructed from the Hammerspoon console and the per-minute layout backups in [data/layout-backups/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/layout-backups/) (the [L006](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L006-layout-restore-of-windows-in-screens) autosave rings record every window's frame each minute):

| Time | Event | Source |
|---|---|---|
| 13:55:46 | Screen off | console |
| 14:41:02 | Wake; windows reappear 14:43:34 (unlock) | console, `windows-reappeared` |
| 14:47:34 | ==🟢All five windows at their normal positions== | `layout-10m-07-c5.json` |
| 14:48:32 | Bear deactivates and fn goes down in the same second (`[shiftFirst] true→false`) | console |
| 14:48–14:49 | Windows take focus in turn — three Bear notes, a Finder window, a kitty session — and each walks right | Bear front-to-back order in the autosave lines |
| 14:49:17 | ==🟣hyper+P (spin)== — the first Hammerspoon hotkey since the runaway began | `[bear-hud] URL hotkey FIRED: P` |
| ~14:50 | A Bear note on the bottom screen takes focus and ==🟢doesn't move== | backups |
| 14:52:35 | First backup with four windows at `x=5960`, one at `5835` | `layout-1m-07-c5.json` |
| 14:58:03 | First message in the spin-opened session | transcript |

The memory of the fix was "hyper+F, pick a feature, open Claude Code". The console has no hyper+F since 11:28 — it was hyper+P (spin), which also opens a session for a feature. Claude Code writes the transcript on the first message, so the 9-minute gap between 14:49 and 14:58 is just reading time.

## Mechanism: one global repeat timer

`bindWithRepeat` used to hand Hammerspoon the same function as both press and repeat callback: `hs.hotkey.bind(mods, key, healed, nil, healed)`. Hammerspoon 1.1.1 implements that repeat in [libhotkey.m](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/hotkey/libhotkey.m) as ==🔴one global `NSTimer`==:

- started *after* the press callback returns (lines 385–387), first firing after `keyRepeatDelay` (0.25 s here), then every `keyRepeatInterval` (0.033 s — ==🔴30 Hz==);
- stopped only by **any** non-repeat Carbon hotkey event, for any hotkey (358–361), by disabling any enabled hotkey (293), or by a callback error (381);
- ==🔴never checks that the key is still down.==

So one missing key-up means the repeat runs until some other hotkey happens to fire. Here the stuck binding was plain fn+→ (Hammerspoon's `END`): `dispatchStepMove("right")` on whatever window has focus. With five screens the config is `multi`, which skips [L010](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L010-move-to-resize)'s per-screen shove and uses WinWin's `stepMove`, which crosses screens: ==🔵a screen width per second== (1/30 of the width per step, 30 steps a second), ending against the right edge of the rightmost display.

## What stopped it

hyper+P is a bear-hud URL hotkey bound with plain `hs.hotkey.bind` — a Carbon hotkey — so its press ran `[keyRepeatManager stopTimer]`. ==🟢Any Hammerspoon hotkey would have done it==, including any stepper combo; clicking windows (the natural reaction) never could.

## Where the key-up went

The repeat is only half the story; something lost End's key-up first. Probes ruled out the obvious suspects.

**The WindowServer matches hotkey releases by keycode only.** [release-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/release-probe.lua) drives throwaway F20 / ⌘F20 hotkeys with synthetic events:

| Test | Key-up shape | Release delivered | Repeats after key-up |
|---|---|---|---|
| T1 | same key, same modifiers | yes | stop |
| T2 | same key, ⌘ added before key-up | yes | stop |
| T3 | ⌘ released before key-up | yes | stop |
| T5 | ==🔴different keycode== | ==🔴no== | ==🔴+15 per 0.5 s until the matching key-up== |

**Releasing fn before → does not lose it.** Only one keyboard is attached — the built-in Apple Internal Keyboard (`hidutil list`) — and macOS's [IOHIDKeyboardFilter](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDEventSystemPlugIns/IOHIDKeyboardFilter.mm) remaps fn+→ to End. In `processModifiedKeyState` (lines 1513–1541), ==🟢releasing fn synthesizes the End key-up for every key it remapped==; the physical → key-up that follows goes out unremapped, as a harmless stray.

**Hammerspoon's own taps can't eat it.** They listen for `flagsChanged` ([bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua), [mousemove.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/mousemove.lua)), `keyDown` (bear-paste) and `mouseMoved` — never `keyUp`. And `mousemove`'s fn+drag only raises the window it grabs; the runaway moved the *focused* window.

**Not Hammerspoon's known repeat bugs either.** Hammerspoon has a documented runaway class ([#1178](https://github.com/Hammerspoon/hammerspoon/issues/1178), [#3584](https://github.com/Hammerspoon/hammerspoon/issues/3584#issuecomment-1890769365), [#3589](https://github.com/Hammerspoon/hammerspoon/issues/3589), closed without a code change): the repeat timer starts *after* the press callback returns, so a callback that spins the event loop (`hs.osascript` does) handles the key-up first, and the timer then starts with nothing left to stop it. #3589 also reports it with merely slow callbacks. Both shapes were probed here against Hammerspoon's own repeat, and ==🟢neither reproduces== on this macOS with 1.1.1:

| Probe | Shape | Result |
|---|---|---|
| [nested-release-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/nested-release-probe.lua) | press callback posts its own key-up, then a 57 ms AX call | key-up handled after the callback; 0 repeats |
| [slow-callback-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/slow-callback-probe.lua) | 80 ms repeat callbacks (longer than the 33 ms interval) | key-up handled at once; repeats stop at 4 |

The console agrees: no hotkey warnings all day — no release for an unknown hotkey, no repeat timer started over a running one. ==🟣End's key-up never reached Hammerspoon.==

**Left standing**: something upstream dropped it, and ==🟣the timing points at wake==. The runaway began 7½ minutes after wake (5 after unlock), and this bug has only ever shown up after coming back to the computer. Plausible culprits are an event tap left in a bad state by sleep/wake (Hyperkey's is known to die silently on this machine) or the taps in Raycast, BetterTouchTool and rcmd. That can't be proven after the fact, since nothing logged hotkey releases.

## The fix

[stepper.lua:898](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) — `bindWithRepeat` no longer passes a repeat callback to Hammerspoon. It binds press and release, and runs its own timer with the same delay and interval, which on every tick:

1. ==🟢requires every modifier held at press (fn included) to still be held== (`hs.eventtap.checkKeyboardModifiers()`), and stops otherwise;
2. stops after ==🔵5 s== regardless (`REPEAT_MAX_SECONDS`) — a held key crosses a whole screen in about a second;
3. stops on a callback error, as Hammerspoon's repeat did.

With a lost key-up, the window now moves only as far as the keys were actually held: once fingers leave fn, the next tick (33 ms at most) stops the repeat. And if the key-up — or another press — was already handled while the first step ran, it doesn't start repeating at all, closing the upstream hole above for any future callback that spins the event loop.

Updating Hammerspoon wouldn't have helped: ==🔵1.1.1 is the latest release== (2026-02-26), and master is two commits ahead (an appcast bump and an `hs.urlevent` fix), neither touching hotkeys.

A stop that isn't followed by the hotkey's release within 2 s is logged:

```
[stepper] lost key-up: end in Bear, repeat stopped after 0.3s (fn released)
```

The 2 s grace exists because releasing fn first is normal: End's key-up arrives milliseconds after the modifier change, and a tick can land in between.

Behavior changes: letting go of a modifier mid-hold now stops the repeat (it used to keep repeating the original operation); holds longer than 5 s stop repeating; an unrelated Hammerspoon hotkey no longer cuts a stepper repeat short.

## Verification

[repeat-guard-test.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/repeat-guard-test.lua) binds a throwaway F20 through the real `bindWithRepeat` (exposed as `_G._stepper.bindWithRepeat`), counts calls instead of moving windows, and fakes the physical modifiers by swapping `hs.eventtap.checkKeyboardModifiers`:

| Scenario | Expected | Observed |
|---|---|---|
| S1 hold 0.8 s, fn held | repeats, stops at key-up | 18 calls, then flat ==🟢✓== |
| S2 key-up withheld, fn released at 0.6 s | stops within a tick, logs | frozen at 30; `lost key-up … (fn released)` ==🟢✓== |
| S3 fn released 20 ms before key-up | stops, no log | flat at 41, no log line ==🟢✓== |
| S4 key-up withheld, no modifiers at press | stops at 5 s, logs | 141 at 4.45 s → 151 at 5.25 s → 151; `(held over 5s)` ==🟢✓== |

A rerun after adding the "already released" check gave the same four outcomes on an idle Hammerspoon. A rerun started right after a reload gave S1 two extra steps after its key-up. Startup work held up the key-up's delivery while the faked fn was still "held" — expected, and bounded by the same checks.

==🟢Physical fn check==: the fake can't prove that the real fn key is visible to `checkKeyboardModifiers`. So a temporary recorder logged every reading the guard took during real fn+←/→ holds: all 28 had fn held (`{fn}` ×21, `{fn, shift}` ×7). A 20 Hz sampler saw each fn press and release, and no legitimate repeat was cut short.

The five displaced windows were restored to their 14:47:34 frames from `layout-10m-07-c5.json`.

## Next time

A `[stepper] lost key-up` line in the console means the guard caught one. ==🔵Both report lines also go to `data/lost-key-ups.log`== (untracked) — the console doesn't survive a Hammerspoon relaunch or reboot — but only for stepper's own keys, so test runs on F20 stay out of it. Since this case the report carries the context that was missing here, from [inputprobe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/inputprobe.lua) and its Swift helper [inputprobe.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/inputprobe.swift) (built on first use, like `display-arrange`):

```
[stepper] lost key-up: end in Bear, repeat stopped after 0.3s (fn released) · 7.5 min after wake · 5.0 min after unlock · secure input off · HID holds: nothing
[stepper] taps that could drop a key-up: BetterTouchTool hid · SiriNCService session · Hyperkey session · Monologue annotated · Siri session | since wake: no change
```

How to read it:

- ==🟣HID holds: end== — the keyboard layer never released End: no key-up was produced, or the fn remap split the pair (End down, plain → up). The fault is below every app.
- ==🟣HID holds: nothing== — the key-up was produced and then dropped before reaching Hammerspoon. The second line lists the only taps that could: enabled, filtering, and receiving key-ups. "since wake" lists key taps that appeared, vanished or switched on/off since the last wake (a census taken at every wake).
- **min after wake / unlock** tests the wake hypothesis; **secure input ON** points at the [orphaned secure input](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-05-20-orphaned-secure-input-kills-all-hotkeys.md) class instead.
- The app named first is the frontmost app at the press.

The probe reads key state through `CGEventSource.keyState(.hidSystemState)`, which needs Input Monitoring; Hammerspoon's grant covers it. Without access it says "unreadable" rather than "nothing". Tap latency stats were left out on purpose: macOS's per-tap numbers jumped to 19–61 s right after synthetic test events, so they would mislead.

A lost key-up from a plain End key on an external keyboard (no fn, nothing to check) is bounded by the 5 s cap instead.

## Appendix: harness notes

- ==🔵`hs.eventtap.event.newKeyEvent(...):post()` does trigger Hammerspoon's own hotkeys== — both scripts depend on it. The 2026-07-17 note that Hammerspoon ignores its own synthetic events applies to `hs.eventtap.keyStroke`, not to posted events.
- Probe on unbound keys (F20): key-downs are consumed by the test hotkey, so nothing reaches the focused app.
- The layout backups are a forensic timeline: the 1 m ring covers 10 minutes and the 10 m ring 100 minutes. Copy the slots you need before they rotate.

Related: [2026-05-20 orphaned secure input kills all hotkeys](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-05-20-orphaned-secure-input-kills-all-hotkeys.md) and [2026-07-17 app-driven snap-detach](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-07-17-app-driven-snap-detach-was-axenhanceduserinterface.md) — the other "outside state silently breaks hotkeys" bugs.
