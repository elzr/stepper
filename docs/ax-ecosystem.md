# The AX ecosystem: who else tweaks global behavior

A registry of the always-on (or often-on) programs on this machine that reach into other apps — via the Accessibility API, event taps, global hotkeys, or window manipulation — and therefore share a playground with [Stepper](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua). They mostly don't know about each other, and several tweak ==🔴global, cross-app state at cross purposes==. This doc is the start of self-consciousness about that mess: name the players, log the evidence, keep the probes handy.

Guiding observation: ==🟣accessibility is the cornerstone of extensibility== — the AX API is the only public door into other apps' text and windows, so every "works everywhere" tool (autocomplete, dictation, window managers, clipboard tools) walks through the same door and trips over the same shared switches.

## Contents

- [Interference classes seen so far](#interference-classes-seen-so-far)
- [The registry](#the-registry)
- [Evidence log](#evidence-log)
- [Field kit: probe & heal](#field-kit-probe--heal)
- [Open questions](#open-questions)

## Interference classes seen so far

1. **==🔴AXEnhancedUserInterface poisoning==** — an app-level "a screen reader is present" flag. AT-ish tools set it (deliberately, to make Chromium build its web-content AX tree; or globally, as VoiceOver-style presence). Side effect: AX window moves/resizes animate and drop position components, breaking Stepper's snap-preserving resizes. Stepper now ==🟢self-heals== (clears it on the focused app before every operation). Full story: [2026-07-17 case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-07-17-app-driven-snap-detach-was-axenhanceduserinterface.md).
2. **==🔴Orphaned secure input==** — a process grabs secure keyboard entry and never releases it, silently killing all Hammerspoon hotkeys. Password prompts, login windows, and password managers are the usual grabbers. Full story: [2026-05-20 case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-05-20-orphaned-secure-input-kills-all-hotkeys.md).
3. **Frame fights** — multiple parties move/resize the same windows: Stepper ops, [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) restores, [screenmemory.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmemory.lua), Raycast window commands, BTT snapping, apps restoring their own frames. Mostly benign today because Stepper is the only habitual mover — but every new tool with window powers is a future fight.
4. **Input-event contention** — flagsChanged/keyDown event taps (bear-hud's raltWatcher carries [shift-first detection](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua) as a passenger), Carbon hotkey namespace, text injectors (Cotypist, Monologue) racing real keystrokes. No confirmed casualty yet; prime suspect pool for "keys behave weird" bugs.

## The registry

All confirmed running as of 2026-07-18. "Reach" = how it touches other apps.

| App | Always-on | Reach | Interference risk |
|---|---|---|---|
| **Cotypist** | ==🔴yes== (login item) | AX text reading + suggestion injection *everywhere by design*; ==🔴stamps AXEnhancedUserInterface on Chromium browsers== to force their AX tree | ==🔴Convicted== Chrome re-poisoner (see evidence log). Its [compatibility page](https://cotypist.app/compatibility) says Chrome works "out of the box" — i.e. it stamps silently; Arc/Dia "need a one-time setting"; its Google Docs dialog is the stamp made visible |
| **Monologue** (Every) | ==🔴yes==, used intensively | Dictation: AX focus/text-field reading, text injection, likely mic-driven AT registration | Prime suspect for the ==🔴original global stamp== (loginwindow included) — dictation engines announce themselves AT-style. Unconfirmed; see open questions |
| **Plaud** | yes (login item) | Meeting capture; possibly AX screen context | Was poisoned 2026-07-17 (victim). No evidence it stamps others |
| **Raycast** | yes | Window Management (AX frame writes), browser extension, AI screen context | Known to leave AXEUI set on apps it manages ([Amethyst #1593](https://github.com/ianyh/Amethyst/issues/1593)); itself re-poisoned within hours of the 2026-07-18 heal — stamper unknown |
| **BetterTouchTool** | yes | Event taps (gestures), window snapping via AX, scripting ([L008 uses it](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/btt-resize-thumbnails.js)) | No evidence it sets AXEUI (it *suffers* from it like all WMs). Frame-fight + event-tap contention candidate |
| **Paste** (wiheads) | yes | Pasteboard polling; AX for paste context | Low. Secure-input interactions possible around password fields |
| **Lunar** | yes | Display control (DDC), [F010 display names](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar) | Low for AX; screen-topology events can race layout restores |
| **macOS AT features** (VoiceOver, Voice Control, Dictation, Full Keyboard Access) | latent | ==🔴Global AXEUI stamping== of every running app when toggled; secure input at login | Any accidental toggle re-poisons everything long-running. loginwindow's stamp is the fossil |
| **Passwords/AutoFill helpers** | latent | Secure keyboard entry | The [secure-input case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-05-20-orphaned-secure-input-kills-all-hotkeys.md) class |
| **Stepper itself** (+ [rcmd.lua](openfile:///Users/sara/.hammerspoon/rcmd.lua)) | yes | Carbon hotkeys, flagsChanged taps, AX frame writes, ==🟢AXEUI clearing==, layout/screen watchers | We are also a tweaker — new modules must assume contested state, never exclusive ownership |

Chrome (and Chromium apps generally) sit on the other side: not tweakers but ==🔵gated AX *targets*== — they only expose web content when someone stamps them, which is why every text tool eventually pokes Chrome's flag.

## Evidence log

- **2026-07-17** — AXEUI sweep found poisoned: Chrome (×2 instances + AuthenticationServicesHelper), Bear (+ QuickLookUIService), Soulver, Soulver Mini, Plaud, Raycast, ==🔴loginwindow==. The loginwindow hit implies a past *global* stamp (system AT toggle or AT-registering app). All healed; Stepper's self-heal shipped the same day.
- **2026-07-18, ~00:30** — Re-probe 8h later: poisoned = ==🔴Chrome, Raycast, loginwindow== only. Bear/Soulver/Plaud still clean → no global re-stamp; these were *targeted*. Chrome's re-stamp coincided with opening a Google Sheet and Cotypist's "Enable Accessibility in Google Docs" dialog (flashes, then auto-closes once it detects the tree) → ==🟢Cotypist confirmed as the Chrome stamper==. Raycast's stamper unidentified. loginwindow either rejects our heal write (privileged) or is re-stamped at unlock — treat as fossil, not actionable.

## Field kit: probe & heal

The `hs` CLI is ==🔴NOT the bare `hs` in PATH== (that's npm's http-server) — use `/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs`.

**Sweep — who's poisoned right now:**

```bash
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "local t={} for _,a in ipairs(hs.application.runningApplications()) do local ax=hs.axuielement.applicationElement(a) if ax and ax:attributeValue('AXEnhancedUserInterface')==true then t[#t+1]=a:name() end end return table.concat(t, ', ')"
```

**Heal all now** (Stepper already heals the focused app on every keypress; this sweeps the rest):

```bash
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "for _,a in ipairs(hs.application.runningApplications()) do local ax=hs.axuielement.applicationElement(a) if ax and ax:attributeValue('AXEnhancedUserInterface')==true then ax:setAttributeValue('AXEnhancedUserInterface', false) end end return 'healed'"
```

**Catch a stamper red-handed** (paste into the Hammerspoon console; logs transitions with the frontmost app at that moment — the frontmost app when a stamp appears is usually the trigger context):

```lua
_G.axeuiWatch = hs.timer.doEvery(30, function()
  _G.axeuiState = _G.axeuiState or {}
  for _, a in ipairs(hs.application.runningApplications()) do
    local ax = hs.axuielement.applicationElement(a)
    local now = ax and ax:attributeValue("AXEnhancedUserInterface") == true
    local key = a:name() or tostring(a:pid())
    if _G.axeuiState[key] ~= nil and _G.axeuiState[key] ~= now then
      print(string.format("[axeui] %s: %s→%s (frontmost: %s)", key,
        tostring(_G.axeuiState[key]), tostring(now),
        (hs.application.frontmostApplication():name() or "?")))
    end
    _G.axeuiState[key] = now
  end
end)
```

## Open questions

- ==🔵Who did the original global stamp?== Monologue's AT registration is the prime suspect (intensive use, dictation engines announce themselves); an accidental VoiceOver/Voice Control toggle is the alternative. The watcher snippet can settle it: a global stamp poisons *everything at once*.
- ==🔵Who re-stamps Raycast?== Candidates: Cotypist autocompleting in Raycast's text fields, Monologue dictating into Raycast, or Raycast's own AI/extension machinery self-setting.
- Does Cotypist's Docs button *also* flip Google Docs' internal screen-reader mode (⌘⌥Z / "screen reader support"), or only Chrome's flag? Its [troubleshooting docs](https://cotypist.app/help/troubleshooting) mention the Docs-side setting.
- Does Cotypist stamp only Chromium apps, or anything focused that under-exposes AX? (Apps like Bear were poisoned on 2026-07-17 but haven't been re-stamped since — so probably Chromium-only, with Bear's earlier stamp coming from the global event.)
