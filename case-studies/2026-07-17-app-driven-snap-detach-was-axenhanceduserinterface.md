# The app-driven snap-detach bug was AXEnhancedUserInterface

**Date**: 2026-07-17
**Status**: ==🟢Fixed== — self-healing clear in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)
**Perennial since**: early stepper days; repeatedly "fixed" and mysteriously returning

## Contents

- [Symptom](#symptom)
- [The breakthrough observation](#the-breakthrough-observation)
- [Investigation: perfect correlation](#investigation-perfect-correlation)
- [Mechanism](#mechanism)
- [Live proof](#live-proof)
- [Why the bug was perennial](#why-the-bug-was-perennial)
- [What AXEnhancedUserInterface actually is](#what-axenhanceduserinterface-actually-is)
- [The fix](#the-fix)
- [Side discovery: Chrome anchors AX resizes at the bottom](#side-discovery-chrome-anchors-ax-resizes-at-the-bottom)
- [Test-harness gotchas (appendix)](#test-harness-gotchas-appendix)

## Symptom

On a bottom-snapped window, `fn+shift+down` should shrink the window from the top, keeping the bottom edge snapped (the `smartStepResize` wraparound branch). In some apps it instead:

1. First press: ==🔴shrinks from the bottom==, detaching the window from the screen edge by one step.
2. Second press: window no longer reads as snapped, so the combo grows it downward, re-snapping it.
3. Result: an oscillation that never does what you want.

## The breakthrough observation

The key insight (user's): ==🟣the bug is app-driven, not config-driven==. Same config, same screen, same day:

- **Working**: kitty, Finder, Photos, WhatsApp, Telegram
- **Broken**: Chrome, Bear, Soulver

Every previous fix attempt assumed a logic or timing bug in stepper itself, appeared to work, and then the bug "returned" — because the *set of poisoned apps* changed over time, not the code's behavior.

## Investigation: perfect correlation

Probed the app-level `AXEnhancedUserInterface` accessibility attribute on every reported app via `hs.axuielement`:

| App | AXEnhancedUserInterface | User report |
|---|---|---|
| Google Chrome | ==🔴true== | broken |
| Bear | ==🔴true== | broken |
| Soulver | ==🔴true== | broken |
| kitty | ==🟢false== | works |
| Finder | ==🟢false== | works |
| Photos | ==🟢false== | works |
| WhatsApp | ==🟢false== | works |
| Telegram | ==🟢false== | works |

8 for 8. Also found poisoned at sweep time: Soulver Mini, Plaud, Raycast, `loginwindow`, and Chrome's AuthenticationServicesHelper — the `loginwindow` hit suggests a one-time global poisoning event (Voice Control / Dictation / VoiceOver toggle, or an AX-tree-forcing tool like Plaud or Raycast) that stamped every app running at that moment. A grep confirmed ==🟢nothing in our own code sets this attribute==.

## Mechanism

`AXEnhancedUserInterface` is set by assistive-tech clients. While `true`, macOS **animates** AX-initiated window moves/resizes. The `smartStepResize` bottom-snap branch in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) is a three-step dance:

1. `setSize(h - step)` — via [WinWin.spoon](openfile:///Users/sara/.hammerspoon/Spoons/WinWin.spoon/init.lua)
2. read the frame back (captures whatever the app actually did, including app-side clamping — e.g. kitty's cell-grid rounding)
3. `setFrame` with `y = screenBottom - h` to re-snap the bottom edge

With the attribute set, step 1 starts an *animation*; step 2 reads an in-flight frame; step 3 **interrupts the animation, and the position component of the interrupting `setFrame` gets swallowed** — the window ends at its pre-animation y with the shrunk height: detached from the bottom. This is the same attribute that yabai, Rectangle, and Amethyst all carry explicit workarounds for.

## Live proof

Replicated the exact code sequence on the real Chrome window (LG 4K screen, `steph=72`):

- **Poisoned** (`AXEUI=true`): settled at `y=-2046 h=1975` → ==🔴bottomGap=71, detached== — bug reproduced.
- **Healed** (`AXEUI=false`), identical sequence: settled at `y=-1904 h=1904` → ==🟢bottomGap=0, snapped==, shrunk from the top.
- End-to-end via a real hotkey press: the `bindWithRepeat` heal wrapper flipped Chrome's attribute `true→false` in the wild.

## Why the bug was perennial

- The poison arrives ==🟣at runtime, per-app, from external tools== — which apps are broken changes silently.
- App restarts clear it, so "fixes" verified after a restart looked successful.
- Any future assistive-tech use re-poisons apps, so the bug always came back.

## What AXEnhancedUserInterface actually is

Researched 2026-07-17 (post-fix). It's an ==🟣undocumented app-level AX attribute that means "a screen reader is driving this app"==. VoiceOver sets it on apps to announce itself; apps respond by turning on expensive accessibility support they otherwise skip:

- **Chromium/Firefox/Electron** keep their web-content accessibility tree OFF for performance and use this attribute as the screen-reader-detection signal ([Mozilla bug 1664992](https://bugzilla.mozilla.org/show_bug.cgi?id=1664992)). That's why ==🔵every tool that wants to read Chrome's AX tree (dictation apps, AI assistants, automation) must set it on Chrome== — it's the only public switch.
- **AppKit apps** enter an "enhanced UI" mode where, among other things, ==🔴AX-initiated window moves/resizes become animated== (`setFrame:display:animate:YES`-style). Animated = non-atomic + interruptible: a rapid position+size sequence interrupts its own animation and loses components. Apple has never documented the animation side effect; an [Apple dev forums thread](https://developer.apple.com/forums/thread/659755) about it went unanswered.
- **Electron** added `AXManualAccessibility` ([PR #10305](https://github.com/electron/electron/pull/10305)) as the sane alternative — enables the AX tree *without* the animation. Chrome proper still only honors `AXEnhancedUserInterface`.

Every macOS window manager independently rediscovered this and ships the same workaround: [Rectangle](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift) (three modes; its `disableOnly` = our approach), [Phoenix PR #310](https://github.com/kasper/phoenix/pull/310), Hammerspoon's `setFrameCorrectness`, yabai, Amethyst. [Amethyst #1593](https://github.com/ianyh/Amethyst/issues/1593) documents Raycast's Window Management leaving it set — ==🔴breaking other WMs even after Raycast was uninstalled== — the same orphaned-poison pattern we hit.

**Likely poisoners here** (2026-07-18 follow-up: Cotypist convicted for Chrome — full registry and evidence log now live in [docs/ax-ecosystem.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/ax-ecosystem.md)) (loginwindow being stamped implies a system-wide AT event): a VoiceOver/Voice Control/Dictation toggle at some point, plus per-app setters like Raycast (AX features) or Plaud (screen context). ==🟢BTT and rcmd exonerated== — no evidence BTT sets it (it *suffers* from it), and our rcmd is a grep-verified-clean local lua. Long-lived processes (Chrome with session restore, Bear, Soulver, loginwindow) kept the stamp; frequently-restarted apps (kitty, Telegram, WhatsApp, Photos) shed it — hence the "random" app split.

## The fix

Self-healing at the single choke point every stepper hotkey flows through — `bindWithRepeat` now clears the attribute on the focused app before every operation:

```lua
local function clearEnhancedUI()
  local win = hs.window.focusedWindow()
  if not win then return end
  local app = win:application()
  if not app then return end
  local ax = hs.axuielement.applicationElement(app)
  if ax and ax:attributeValue("AXEnhancedUserInterface") == true then
    ax:setAttributeValue("AXEnhancedUserInterface", false)
  end
end
```

Cost: one AX attribute read per keypress (sub-ms); a write only when poisoned. Not restored afterward — whoever needs it (VoiceOver etc.) re-sets it continuously, and leaving it cleared keeps ops like [mousemove.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/mousemove.lua) drags safe too. ==🟢Any future re-poisoning heals on the very next keypress== — the arms race is won by being last.

## Side discovery: Chrome anchors AX resizes at the bottom

Even healed, Chrome applies a bare `setSize` keeping the **bottom-left (Cocoa origin)** fixed — the opposite of the AX top-left convention kitty et al. follow. The existing read-back + re-snap design in `smartStepResize` self-corrects either anchor, which is why it's the right architecture — it only ever breaks when animation makes the read-back lie. (Also: Chrome rounds odd heights, e.g. 1974→1975.)

## Test-harness gotchas (appendix)

Recorded for future live-debugging sessions:

- ==🔵`hs` in PATH is npm's http-server==, not the Hammerspoon CLI. Use `/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs` (see [hs-console.sh](openfile:///Users/sara/bin/hs-console.sh)).
- ==🔵Hammerspoon ignores its own synthetic events== — `hs.eventtap.keyStroke` cannot trigger hs hotkeys (anti-recursion). Post from outside: `osascript -e 'tell application "System Events" to key code 121 using {shift down}'` (121 = pagedown).
- ==🔵Synthetic shift trips shift-first mode== — `shiftFirstCallback` sets `shiftFirstMode` on `shift && !fn`, so synthetic shift+pagedown always takes the `topLeftAnchorResize` variant, never `smartStepResize`. fn can't be synthesized via System Events.
- ==🔵Poisoned animations leave a landmine==: a `setFrame` issued while `AXEUI=true` animates; clearing the attribute and issuing the next op can make Chrome reconcile to the *origin frame of the previous animation*. Always heal first, then move windows.
- Chrome's 1×1 "Find in page" ghost window can steal `focusedWindow()` during scripted focus tests (layout.lua already skips it as `save-skip-ghost`).

Related: [2026-05-20 orphaned secure input kills all hotkeys](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-05-20-orphaned-secure-input-kills-all-hotkeys.md) — the other class of "external state silently breaks hotkeys" bug. Resize semantics history: [L001 edge resize behavior](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/docs/research/L001-edge-resize-behavior.md).
