# Fix: app-driven snap-detach on resize (AXEnhancedUserInterface self-heal)

**Date**: 2026-07-17

`fn+shift+down` on a bottom-snapped window detached it instead of shrinking from the top — but only in some apps (Chrome, Bear, Soulver), while others (kitty, Finder, Photos, WhatsApp, Telegram) worked. Root cause: those apps had the app-level ==🔴`AXEnhancedUserInterface`== accessibility attribute set by external assistive-tech tooling, which makes AX moves/resizes animate — and the re-snap `setFrame` in `smartStepResize` ([stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)) interrupts the animation, losing its position component. The initial shrink comes from [WinWin.spoon](openfile:///Users/sara/.hammerspoon/Spoons/WinWin.spoon/init.lua)'s `stepResize`, whose read-back the animation corrupts.

**Change**: `bindWithRepeat` now wraps every binding with `clearEnhancedUI()`, which clears the attribute on the focused app before each operation. ==🟢Self-healing==: future re-poisoning is cured on the next keypress. ==🔵Cost: one sub-ms AX read per keypress==, a write only when poisoned.

Full story with live probes and the 8-app correlation table: [case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-07-17-app-driven-snap-detach-was-axenhanceduserinterface.md), alongside the earlier [secure-input case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-05-20-orphaned-secure-input-kills-all-hotkeys.md) in [case-studies/](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/).
