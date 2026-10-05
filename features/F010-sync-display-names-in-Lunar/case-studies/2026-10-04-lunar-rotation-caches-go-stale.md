# Case: the deliberate hub swap — Lunar accepts the rotation and moves nothing, so the guard now rotates through MonitorPanel itself (2026-10-04)

**Project:** [stepper](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper) × [F010-sync-display-names-in-Lunar](https://stepper.internal/features/F010-sync-display-names-in-Lunar/) × [F027-worldclass-code-debugging](https://fleet.internal/features/F027-worldclass-code-debugging/)

**The symptom:** At 22:16 the two OWC hubs went back into the Mac deliberately swapped, to test the guard changes from the evening before. Both 37" Samsungs came up ==🔴upside down and mirrored== again. The user saw "a rotation try, or something that glitched at both at the same time a few seconds after I connected them", and the panels stayed wrong.

==🟣The truth: the guard did everything right except the one step that touches the hardware. It identified both panels by text serial 5 s after the transition, asked Lunar to rotate them, read back Lunar's belief, nudged through the other value as designed on 2026-10-03, and Lunar's own numbers changed to the requested values — while WindowServer never logged a single rotation. Lunar rotates through an `MPDisplay` object it caches the first time it sees a UUID; after a hub re-enumeration that object is stale and MonitorPanel's setter on it is silent. The "glitch at both" was macOS applying the saved (swapped) arrangement as each panel connected, not the guard. The guard now carries its own rotation tool: a fresh MonitorPanel manager per call, addressed by the display's current ID, plus both origins in one CoreGraphics transaction.==

## Contents

- [GICV](#gicv)
- [Timeline](#timeline)
- [Why Lunar's rotation moved nothing](#why-lunars-rotation-moved-nothing)
- [Why the two LGs never have this problem](#why-the-two-lgs-never-have-this-problem)
- [The fix](#the-fix)
- [Verification](#verification)
- [What port-independence means now](#what-port-independence-means-now)
- [Wrong turns](#wrong-turns)
- [Meta-lessons](#meta-lessons)
- [Tags](#tags)

## GICV

> **GOAL:** Plugging the hubs into either Mac port gives the same desk within seconds: both Samsungs portrait on their sides, windows on the screens they were saved on.
>
> **INVARIANT:** Rotation is applied only to the display ID the text-serial probe named, never by UUID or position; no rotation or DDC traffic to sleeping displays; macOS's arrangement store is left to macOS.
>
> **COMPLETION:** After a swap, the guard rotates and re-places both panels on its own, and WindowServer's `setting rotation angle` lines show each rotation landing.
>
> **VERIFICATION:** Restored by hand with the new tool at 22:30 (both rotations `changed: true`, both origins landed in one transaction, guard `ok (screens)`); then one panel flipped on purpose at 22:34:01 and the guard's own screen-change trigger fixed it unattended by 22:34:14.

## Timeline

Sources: WindowServer (`/usr/bin/log show --predicate 'process == "WindowServer"'`, the `SkyLight:display` lines), the Hammerspoon console (`~/bin/hs-console.sh 0`), `Lunar @ --remote displays`, the tool's own JSON.

| Time | What | Source |
|---|---|---|
| 22:16:10 | Hub A in: LG `1FE47444` lands on slot `d010` and is **Adjusted** `BF53 → CB72` (macOS carries a unique-serial display's UUID to its new slot) | WindowServer |
| 22:16:12 | First Samsung on slot `e010` → `Twins: found with optional key 7BAA` → UUID `FD24B45E` → `setting rotation angle 0 -> 270` | WindowServer |
| 22:16:13–15 | Hub B in: LG `797F8F46` adjusted `7BAA → DFF0` (slot `d000`); second Samsung on slot `e000` → key `BF53` → `86D1A557` → `0 -> 90` | WindowServer |
| 22:16:25–32 | Screens 1 → 5, transition native → quad-32, 15 windows restored by virtual side (`saved@right` → "LS37D70xE (1)" = `86D1A557` = ==🔴the physical left panel==) | console |
| 22:16:33 | Guard: `fixing (transition): left HNTL300014 rotation 90, want 270; right HNTL300013 rotation 270, want 90` — the probe had `HNTL300014` on `dispext3` = display 2 = `86D1A557`, `HNTL300013` on `dispext1` = display 5 = `FD24B45E` | console, display-serials |
| 22:16:33–36 | `Lunar @ --remote displays 86D1A557… rotation 270`, then `FD24B45E… rotation 90`; Lunar answers `rotation: N` each time | console |
| 22:16:35 | F010 Lunar sync: "No changes needed" (names and DDC match macOS's virtual sides) | console |
| 22:16:53 | `attempt 1 failed (rotation didn't land for HNTL300014, HNTL300013)` | console |
| 22:16:58–22:17:03 | Attempt 2: `Lunar already believes 270, nudging through 90 then 270` / `believes 90, nudging through 270 then 90` — the 2026-10-03 fix running as designed | console |
| 22:17:23 | `gave up after 2 attempts` — ==🔴no `setting rotation angle` in WindowServer after 22:16:15== | console, WindowServer |
| 22:24 | Lunar's table: `←Left` (`FD24B45E`, ID 5) Rotation **90**, `Right→` (`86D1A557`, ID 2) Rotation **270** — the opposite of macOS (270 / 90). ==🔵Lunar's numbers took the guard's values; the panels did not== | `Lunar @ --remote displays` |
| 22:26–29 | MonitorPanel's selectors dumped with the ObjC runtime; `display-arrange.swift` written and built; `list` shows all five displays with `canRotate: true` | tool |
| 22:29:5x | By hand: `rotate 2 270` → `{"changed":true,"from":90}`, `rotate 5 90` → `{"changed":true,"from":270}`, `place 2:-2160,-2757 5:3840,-3147` → both landed | tool |
| 22:30:15 | Guard: `ok (screens)`; 22:30:18 layout: 9 windows drifted → restored to the physical sides; 22:30:30 F010: `←Left`/`Right→` names swapped back onto the right UUIDs, Lunar restarted, DDC wiring verified | console |
| 22:33:41 | Hammerspoon reloaded with the rewritten guard: `ok (init)` | console |
| 22:34:01 | Test: `display-arrange rotate 5 270` puts the right panel wrong on purpose | tool |
| 22:34:04–14 | `screens-debounced: 5 → 5`; guard `fixing (screens): right HNTL300013 rotation 270, want 90` → `rotating display 5 from 270 to 90` → `fixed: left HNTL300014 rot 270 … at (-2160,-2757); right HNTL300013 rot 90 … at (3840,-3147)` — ==🟢13 s from flip to fixed, unattended== | console |

## Why Lunar's rotation moved nothing

The 2026-10-03 case study blamed an equal-value no-op: Lunar's `rotation` already held the requested number, so the set did nothing. That was the first why. The nudge built for it changed the input (90 then 270) and still nothing moved — which refutes "equal value" as the whole story. Lunar 6.11's [Display.swift](https://github.com/alin23/Lunar/blob/master/Lunar/Data/Display.swift) shows the second why:

```swift
lazy var panel: MPDisplay? = DisplayController.panel(with: id)   // resolved once, at first use
@objc dynamic lazy var canRotate: Bool = canChangeOrientation      // cached as well

@Published @objc dynamic var rotation = 0 {
    didSet {
        guard DDC.apply, canRotate, VALID_ROTATION_VALUES.contains(rotation) else { return }
        mainAsync { [weak self] in
            self?.reconfigure { panel in       // DisplayController.panelManager, created at launch
                panel.orientation = self.rotation.i32
                …
```

Three facts fix the diagnosis without seeing inside Lunar:

- ==🔵Lunar's stored numbers changed== to exactly what the guard sent (table at 22:24: the opposite of macOS), so the CLI reached the property.
- ==🔴WindowServer logged no rotation== between 22:16:15 and the manual fix, so `panel.orientation =` reached nothing live — a nil panel, a stale `MPDisplay`, or a cached `canRotate` of false all look the same from outside, and Lunar's unified log has nothing at the default level.
- ==🟢A fresh `MPDisplayMgr` in a new process rotated the same display IDs at once==, with `canChangeOrientation` true on all five.

Lunar had been running since 14:43, across the disconnect and the re-enumeration; its `Display` objects for the two UUIDs kept the panel objects from before. The command is not a reliable actuator after a re-enumeration, and the guard's verification (`rotation didn't land`) was the only thing standing between "Lunar said yes" and "nothing happened".

## Why the two LGs never have this problem

The same WindowServer log answers the user's question. For the LGs it prints `Adjusting: '1FE47444-…': BF53-… -> CB72-…`: a display with a unique numeric EDID serial keeps its UUID and macOS re-keys it onto whatever slot it lands on. For the Samsungs it prints `Twins: found with optional key …` and the UUID is the slot's. macOS reads the text serial (`asn:` is in the same log line) and does not use it for identity. The guard uses it — that part worked — but the rotation it then asked for never reached the hardware.

## The fix

1. ==🟢[display-arrange.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/display-arrange.swift)== — a Swift CLI that `dlopen`s MonitorPanel.framework and calls it through `@objc` protocols mirroring the selectors dumped with `class_copyMethodList` (`MPDisplayMgr`: `displays`, `displayWithID:`, `tryLockAccess`, `notifyWillReconfigure`, `notifyReconfigure`, `unlockAccess`; `MPDisplay`: `displayID`, `orientation`/`setOrientation:`, `canChangeOrientation`, `uuid`, `displayName`). `rotate <id> <deg>` builds a fresh manager, locks (40 tries, 0.25 s apart), sets the orientation inside will/did-reconfigure, and waits until `CGDisplayRotation` reports the new angle. `place <id>:<x>,<y> …` sets every origin inside one `CGBeginDisplayConfiguration … CGCompleteDisplayConfiguration(.permanently)` and waits for the bounds. `list` prints what MonitorPanel sees. JSON out, exit 1 on failure.
2. [displayguard.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/displayguard.lua) — the Lunar path (`lunarBelievedRotation`, `lunarRotate`, the nudge) is gone. `ensureTool` compiles the binary with `/usr/bin/swiftc` when it is missing or older than the source; `rotateDisplay` calls the tool by display ID with one retry; `applyModes` keeps `hs.screen:setMode` per display, then `applyOrigins` places every drifted origin in one call. The watchdog allows 180 s for the slower worst case.
3. [.gitignore](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/.gitignore) ignores the built binary; only the source is tracked. [F010 README](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/README.md), the project [README](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/README.md) and the memory notes ([project_display_configs.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/project_display_configs.md), [display_rotation_apple_silicon.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/display_rotation_apple_silicon.md)) now describe this path.

Why one transaction for the origins: after a swap each Samsung sits on the spot the other belongs on. `hs.screen:setOrigin` one display at a time asks macOS to overlap two displays, and macOS nudges the first one away before the second moves; the earlier guard only ever placed panels that had come up at the default spot next to the built-in, where the sequence did not matter.

## Verification

| Step | Result |
|---|---|
| `display-arrange list` before the fix | five displays, IDs and UUIDs equal to `hs.screen`, `canRotate` true on all |
| `rotate 2 270` (physical left, `HNTL300014`) | `changed: true, from: 90`, CoreGraphics reported 270 within the poll |
| `rotate 5 90` (physical right, `HNTL300013`) | `changed: true, from: 270` |
| `place 2:-2160,-2757 5:3840,-3147` | both bounds landed, one transaction |
| Guard after the manual fix | `ok (screens)`, origins unchanged in [display-guard.json](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/data/display-guard.json) |
| Layout and F010 afterwards | 9 drifted windows restored to the physical sides; Lunar relaunched with `←Left`/`Right→` on the right UUIDs, DDC verified |
| Unattended test, right panel flipped with the tool | detected 5 s later by the screen-change trigger, rotated, verified: `fixed` at 22:34:14 |

The physical hub swap itself was only fixed by hand (the tool was written after the guard had given up); the unattended run exercised the same code path through the guard's own trigger on one panel.

## What port-independence means now

macOS keeps saving the arrangement for whichever UUID pair is live, and the pair is a property of the cabling. The fix at 22:30 wrote `86D1A557` = left/270, `FD24B45E` = right/90 into macOS's store for the swapped cabling; the usual cabling will bring that pair up flipped next time, the guard will fix it in about ten seconds, and the store flips back. ==🟣A few seconds upside down after each re-cabling is the floor for software==; making macOS itself indifferent needs the two panels to differ in EDID (an in-line DisplayPort EDID emulator with a different serial on one of them).

## Wrong turns

- ==🔴`CGDisplayCreateUUIDFromDisplayID` via `@_silgen_name`== compiles and fails to link for arm64 on macOS 27; MonitorPanel's own `uuid` property gives the same string.
- `objc_copyClassNamesForImage` with the framework's nominal path returned nothing (the dyld shared cache registers another path); dumping the known class names directly worked.
- Lunar's unified log (`fyi.lunar.Lunar`) has no rotation or panel lines at the default level, so the exact branch inside Lunar is unproven; the fix does not depend on it.
- The "glitch at both at the same time" was looked for in the guard's window first. It matches WindowServer's own `0 -> 270` and `0 -> 90` at connect time: macOS applying the saved arrangement for the swapped pair, 3 s apart, before the guard ran.

## Meta-lessons

1. ==🔴Verify the actuator, not the messenger.== `rotation: 270` on stdout is a messenger; WindowServer's `setting rotation angle` is the receipt. The 2026-10-03 guard already checked the receipt — that check is why this was a clean diagnosis instead of a mystery. [F027 §1](https://fleet.internal/features/F027-worldclass-code-debugging/#1-test-gauntlets-not-assumptions).
2. ==🔵One why deeper.== The equal-value no-op was real and was not the cause; the nudge that answered it changed the input and proved the actuator dead. [feedback_one_why_deeper.md](openfile:///Users/sara/.claude/projects/-Users-sara-Library-CloudStorage-Dropbox-projects-log-2025-hammerspoon-stepper/memory/feedback_one_why_deeper.md).
3. ==🟢Fewer parties between the decision and the hardware.== The guard knew the right display ID all along; routing it through a third-party app's UUID-keyed cache added the one failure that mattered. A private framework called with the current ID has no cache to go stale.
4. ==🟣Test through the same trigger as the incident.== Flipping one panel with the tool and letting the screen watcher notice it exercised the guard's real entry point, not a console call.

## Tags

- samsung-ls37d70xe, twin-display, windowserver-skylight, connection-slot, lunar-rotation-stale-panel, monitorpanel, mpdisplaymgr, display-arrange, cgbegindisplayconfiguration, displayguard, owc-hub, hammerspoon, swift-objc-runtime
- Lunar rotates through `lazy var panel: MPDisplay?` cached at first sight of a UUID; after a re-enumeration the command updates Lunar's number and WindowServer sees nothing
- unique-serial displays are "Adjusted" onto their new slot; twins take the slot's key
- related: [2026-10-03-swapped-hubs-flip-the-samsungs.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/case-studies/2026-10-03-swapped-hubs-flip-the-samsungs.md), [2026-10-03-lunar-sliders-crossed-identical-samsungs.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/case-studies/2026-10-03-lunar-sliders-crossed-identical-samsungs.md), [display-serials.py](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/F010-sync-display-names-in-Lunar/display-serials.py), [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua)
