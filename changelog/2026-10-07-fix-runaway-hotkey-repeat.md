# Fix: windows walking to the screen edge after a lost key-up (guarded key repeat)

**Date**: 2026-10-07

Every window that took focus kept stepping right on its own until it hit the right edge of the right Samsung — four ended 40 px from off-screen. Root cause: ==🔴Hammerspoon's hotkey repeat is one global timer that only stops at the next hotkey event==, and the fn+→ key-up never arrived, so the move-right repeat ran at 30 Hz for about a minute until an unrelated hotkey (hyper+P) stopped it.

**Change**: `bindWithRepeat` in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) runs its own repeat instead of Hammerspoon's. ==🟢Each tick requires the modifiers held at press (fn included) to still be held==, holds stop repeating after 5 s, a press whose key-up was already handled never starts repeating (Hammerspoon issues #1178/#3584/#3589), and a stop that never gets its key-up is logged as `[stepper] lost key-up: …` with the frontmost app — evidence for whichever event tap is eating key-ups. ==🔵Cost: one modifier-state read per repeat tick.==

Full story — timeline from the layout backups, Hammerspoon and Apple HID source, probe tables, regression test: [case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat-after-lost-key-up.md), with its scripts in [2026-10-07-runaway-hotkey-repeat/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-07-runaway-hotkey-repeat/).
