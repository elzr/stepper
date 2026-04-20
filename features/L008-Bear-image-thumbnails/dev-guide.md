# L008 Dev Guide — how paste-and-shrink actually works

Implementation deep-dive for [L008-Bear-image-thumbnails](https://stepper.internal/features/L008-Bear-image-thumbnails/). The [README](README.md) is the entry point; this doc is for when you come back to change something.

==🟣Framing==: the essence of this feature is trivial — append `<!-- {"width":150} -->` whenever Bear inserts an image. All the complexity below is about ==🔴"when to fire"==, because Bear flattens images and format glyphs (blockquote bars, bullets, HRs) to the same `￼` placeholder in the AX layer.

## Contents

- [The user flow](#the-user-flow)
- [Architecture in one picture](#architecture-in-one-picture)
- [The ￼ placeholder, and why AXValue lies](#the--placeholder-and-why-axvalue-lies)
- [The format-glyph trap](#the-format-glyph-trap)
- [The intent gate — hybrid observer + eventtap](#the-intent-gate--hybrid-observer--eventtap)
- [How to verify a change is working](#how-to-verify-a-change-is-working)
- [Dead ends we explored](#dead-ends-we-explored)
- [Gotchas & edge cases](#gotchas--edge-cases)
- [Skill stack we're building with AX](#skill-stack-were-building-with-ax)

## The user flow

1. User copies an image (screenshot, Finder, web).
2. User pastes with ⌘V into any Bear note.
3. Bear inserts the image as a full-width embed (its default).
4. ==🟢Within ~50ms, [bear-paste.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-paste.lua) attaches `<!-- {"width":150} -->` to the embed's markdown==. Bear re-renders it as a 150px thumbnail.
5. If the user wants the full size back, one ⌘z removes the comment (image stays). A second ⌘z removes the whole paste.

Plain-text pastes, or any paste where the clipboard isn't an image, passthrough untouched — the module's filter bails on `hs.pasteboard.readImage() == nil`.

## Architecture in one picture

==🟣Two subsystems==: an AX observer that detects *what* changed in Bear, and a keystroke eventtap that detects *user intent* (a paste was just requested). The observer handles the write; the eventtap stamps a short-lived "intent" timestamp that the observer gates on.

```
 ┌──────────────────────────────────────────────────────────────┐
 │  Bear (app, pid=NNNN)                                        │
 │                                                              │
 │   AXApplication ── AXWindow ── AXScrollArea ── AXTextArea    │
 │                                                              │
 │   AXValue = "...text... ￼ ...more text..."                  │
 │            (￼ = one U+FFFC char per embed OR format glyph)  │
 └──────────────────────────────────────────────────────────────┘
           ▲                              ▲
           │ 1. AXSelectedTextChanged      │ 3. setAttributeValue(
           │    notification on paste      │    "AXSelectedText",
           │                               │    '<!-- {"width":150} -->')
           │                               │
 ┌─────────┴──────────────────────────────┴──────────────────────┐
 │  Hammerspoon / bear-paste.lua                                 │
 │                                                               │
 │   ┌──────────────────────────┐   ┌─────────────────────────┐ │
 │   │  AX observer             │   │  Intent eventtap        │ │
 │   │  hs.axuielement.observer │   │  hs.eventtap.new(       │ │
 │   │    on AXSelectedText-    │   │    keyDown, ...)        │ │
 │   │    Changed               │   │                         │ │
 │   │                          │   │  Stamps on:             │ │
 │   │  Filter: ffc+1 AND       │   │   • ⌘V (Bear front)     │ │
 │   │    clipImg AND           │──▶│   • ⌘⇧Space→Enter       │ │
 │   │    (recent intent signal)│   │     (Paste app commit)  │ │
 │   │                          │   │                         │ │
 │   └──────────────────────────┘   └─────────────────────────┘ │
 │                                                               │
 │      2. read intent timestamp, decide whether to fire         │
 └───────────────────────────────────────────────────────────────┘
```

==🔵Key move==: the observer is attached at the ==**application**== element, not a specific AXTextArea. Notifications from descendant elements (any note's textarea) bubble up to the app-level observer. This avoids the "which textarea is focused *right now*" problem at startup.

==🔵The eventtap is non-intercepting==: it returns `false` from every callback so keystrokes pass through to Bear unchanged. It's purely for *signal* — it stamps timestamps into module state that the observer gate checks. This is very different from the earlier abandoned design that tried to intercept ⌘V and trigger the write from the tap (see [dead ends](#dead-ends-we-explored)).

## The ￼ placeholder, and why AXValue lies

Bear represents every embed (image, PDF attachment) in its AX text layer as exactly ==one `￼` character== — U+FFFC, "Object Replacement Character," 3 bytes in UTF-8. The embed's real markdown (`![](image.png)<!-- {"width":150} -->`) lives in Bear's SQLite store, not in the AX tree.

This has massive consequences for testing:

- ==🔴Adding a width comment to an embed does NOT grow AXValue==. The `￼` is still one character; the comment is metadata attached to the same embed.
- `setAttributeValue("AXSelectedText", '<!-- ... -->')` at the caret *does* write the bytes — Bear's input handler sees the text, attaches it to the preceding embed, and folds it back into the single `￼` in AXValue.
- ==🔴Checking `lenBefore == lenAfter` to verify success will always report failure==. It's the wrong proxy.

Corollary: ⌘C from inside Bear has a *different* string representation than AXValue. A multi-character selection that includes an embed gets exported as raw markdown, with `![](path)<!-- {...} -->` fully spelled out. That's how BTT's ⌥R round-trips work, and how you can verify a write by hand (⌘A + ⌘C + paste into any other app).

## The format-glyph trap

==🔴The single most expensive discovery of the feature==, the one that stalled shipping for a day. Bear uses `NSTextAttachment` (and therefore `￼`) not just for image/PDF embeds, ==🟣but also for every list-style formatting glyph==: the `>` vertical bar of a blockquote, the filled / hollow / diamond / open-diamond bullet at each nesting level, horizontal rules, checkboxes. Bear literally draws them as tiny images inside the text flow — see the screenshots in the [featurebase node](https://stepper.internal/features/L008-Bear-image-thumbnails/).

Consequences for us:

- ==🔴A `￼`-count delta of +1 is NOT unique to image paste==. Pressing Enter at the end of a blockquote-image line auto-extends the blockquote to the next line → `￼` +1, no paste. Typing `>` at the start of a line → Bear replaces it with a blockquote marker → `￼` +1, no paste. Same for typing `-` or `*` (bullets).
- ==🔵Confirmed visually== by the user: Bear bulleted lists really do show an image glyph (blue filled dot, etc.) as the bullet, and nested levels use different glyph variants. All flattened to the same `￼` in AX.
- ==🔵Diagnosed== with [bear-paste-trace.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-paste-trace.lua) — a log-only clone of the observer that records every `AXSelectedTextChanged` fire to NDJSON so we can correlate key actions with `￼`-count deltas.

The two user-reported repros both reduce to the same root cause:

- ==🔴Repro 1== — Enter on a blockquote line that contains an image. Bear auto-extends the blockquote onto a new line, which adds a `>`-glyph `￼` on the new line. Count goes up by 1. Old trigger fired and injected a `<!-- {"width":150} -->` spuriously.
- ==🔴Repro 2== — prepend `> ` to a just-pasted image. Bear converts the `>` into a blockquote `￼` before the image. Count goes up by 1. Same bug.

The AX layer offers no attribute to tell a format glyph from an image embed. That's what drove the intent-gate design.

## The intent gate — hybrid observer + eventtap

Since we can't distinguish image from format glyph purely from AX state, we rely on ==🟣user keystroke intent==. The observer still handles the state change, but it won't fire unless a paste intent was signalled within a short window. Two signals:

- ==🟢⌘V in Bear==. `hs.eventtap` stamps `recentCmdVAt`. 2s TTL.
- ==🟢⌘⇧Space → Enter state machine==, for [Paste app](https://pasteapp.io/). Verified via [paste-source-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/paste-source-probe.lua) that Paste does NOT synthesize ⌘V when you commit a clip — so ⌘V alone would miss it. State machine: ⌘⇧Space (Bear frontmost) opens a watch; Enter commits and stamps `recentPasteAppAt`; Escape or another ⌘⇧Space cancels the watch (browsing without pasting). 15s watch TTL, 5s post-commit TTL. So if you open Paste just to view history and hit Escape, nothing fires.

Both signals are ==🔵one-shot== — consumed on a successful fire so a follow-up format-glyph event within the TTL doesn't reuse them.

==🔴What's explicitly NOT covered==: drag-and-drop from Finder, Edit→Paste menu. Neither has a keystroke we can latch onto. An earlier iteration used a `hs.pasteboard.changeCount()` gate as a fallback to cover them; we dropped it because it false-fired on the "copy image, type `>`, then paste" edge case. Users on those paths can still use `⌥R` after pasting.

## How to verify a change is working

Three tiers, in order of increasing trust:

1. ==🟢Visual==: paste an image into any Bear note. Does it render small (150px-ish, thumbnail size)? Yes → the comment was attached. No → something else is wrong.
2. ==🔵Clipboard roundtrip==: in a test note with a pasted image, ⌘A + ⌘C, paste into a plain text editor. Is `<!-- {"width":150} -->` in the markdown? Yes → confirmed at the markdown layer.
3. ==🟣Log inspection==: `~/bin/hs-console.sh 30 | grep bear-paste`. Look for `paste→shrink applied`. This is the cheapest check for "did the module's code path fire."

==🔴What NOT to do==: don't check `AXValue` length for growth, and don't search `AXValue` for "width":150". Both are blind to embed-attached metadata.

## Dead ends we explored

==🟣Important distinction== before diving in: the dead ends below all used `hs.eventtap` as a ==**write mechanism**== — intercepting ⌘V and trying to trigger the comment insertion from the tap. The current design uses `hs.eventtap` as a ==**signal-only**== (non-intercepting, returns false, stamps a timestamp). Those are different architectures — the signal-only tap doesn't have the "silent success" instrumentation trap these write-mode taps ran into.

Documented so the next person doesn't retrace them. All of these were implemented in the first session (see [scripts/bear-ax-probe.lua](scripts/bear-ax-probe.lua) for the probe that generated the data and the F027 case study at [case-2026-04-19-silent-wins-bear-ax-embeds.md](https://fleet.internal/features/F027-worldclass-code-debugging/case-2026-04-19-silent-wins-bear-ax-embeds.md) for the full post-mortem).

### 1. Event tap at keyDown + deferred AX write

Registered [hs.eventtap.new](https://www.hammerspoon.org/docs/hs.eventtap.html) for `keyDown`, filtered for cmd-only V, returned false (passthrough), scheduled `hs.timer.doAfter(0.05, function() ta:setAttributeValue(...) end)`. ==🔴Looked like it failed==: `writeOk=true` but AXValue length unchanged. Was actually succeeding — we couldn't see it through AXValue.

### 2. Consume + repost via app-targeted event

Same tap, but returned `true` (consume) and re-fired via `event:post(bearApp)` in a timer. Same apparent failure, same actual success.

### 3. `hs.eventtap.keyStrokes` typing the comment char-by-char

Skipped AX entirely, typed `<!-- {"width":150} -->` as a sequence of keystrokes. Also "failed" by AXValue metric — would have worked if we'd looked at Bear visually. But ==🔴fragile== even if it had: types each char, sensitive to focus changes mid-type.

### 4. AppleScript System Events keystroke

`osascript` calling `tell application "System Events" to keystroke "..."`. Different channel from hs.eventtap, hoped it'd bypass whatever was "blocking" the write. Also "failed" by AXValue metric, actually succeeding. ==🔴Also blocks HS runloop briefly== — `hs.osascript.applescript` is synchronous — so it's a bad path anyway.

### 5. Textarea-scoped observer (first observer attempt)

Attached the observer to the currently-focused AXTextArea at startup. Silently bailed when the focused element wasn't the textarea (sidebar, search field, tag editor). Fixed by moving to app-level attachment.

==🟣The meta-lesson==: six attempts, six identical "failure" signatures, ==all six were actually succeeding==. The instrument was broken, not the system. See the [case study](https://fleet.internal/features/F027-worldclass-code-debugging/case-2026-04-19-silent-wins-bear-ax-embeds.md).

## Gotchas & edge cases

- ==🔴Format-glyph fires pass the `ffc+1` filter==, which is the whole reason we need the intent gate (see [the trap](#the-format-glyph-trap)). Every blockquote extend, bullet creation, HR conversion will match the delta — only the intent gate tells them apart from real pastes.
- ==🔵Bear window switching==: the module tracks `lastCount` per-textarea (keyed by element reference). Switching to a different note resets the baseline so we don't report a spurious large delta across notes.
- ==🔵`inserting` flag==: the AX write itself triggers AXSelectedTextChanged (the caret moves past the inserted comment). We guard against self-induced fires with a one-shot flag.
- ==🔴Undo is 2× ⌘z==: one to remove the comment, one to remove the paste. Arguably a feature (you can un-shrink without losing the image), but document it for users.
- ==🔴Bear must be running at HS init==. If Bear launches later, the observer won't attach. Future improvement: re-attach on `hs.application.watcher.launched`.
- ==🔵Paste-same-image-twice==: ⌘V twice with the same clipboard content ==🟢both fire==. Each ⌘V press stamps a fresh `recentCmdVAt`; the observer consumes it on each fire.
- ==🔵Drag-and-drop and Edit→Paste menu are NOT handled==. No keystroke signal. Use `⌥R` after dropping.
- ==🔵If you press ⌘⇧Space but cancel with mouse-click elsewhere==, the watch sits pending for up to 15s. If a real paste happens in another Bear note during that window and you hit Enter… unlikely sequence, but the watch could mis-claim it. Mitigated by: watch clears on Esc or a second ⌘⇧Space, and TTL expires in 15s.

## Skill stack we're building with AX

Stepper now uses [hs.axuielement](https://www.hammerspoon.org/docs/hs.axuielement.html) in three distinct ways, and the patterns are transferable:

- [lua/bear-hud.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-hud.lua) — ==🔵reads + writes==: persists per-note caret position and scroll offset. Classic state-preservation use of AX.
- [lua/bear-paste.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/bear-paste.lua) (this feature) — ==🔵observer + intent-gated writes==: reacts to app-level notifications, cross-checks with a non-intercepting keystroke tap for paste intent, modifies state in response.
- [scripts/bear-ax-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-ax-probe.lua) — ==🔵diagnostic probes==: dumps AX state for ad-hoc investigation.
- [scripts/bear-paste-trace.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-paste-trace.lua) — ==🟣log-only observer==: mirrors bear-paste.lua's wiring but writes nothing, dumping every fire to NDJSON. Essential for diagnosing the format-glyph trap.
- [scripts/drive-trace-run.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/drive-trace-run.lua) — ==🟣synthetic user driver==: fires reproducible paste / blockquote / `> ` sequences into a specific test note. Has AX-focus safety checks after the time we accidentally drove scenarios into the wrong note.
- [scripts/paste-source-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/paste-source-probe.lua) — ==🟣event-source inspector==: records `⌘V` events' source PID / stateID, so "does app X actually synthesize ⌘V?" becomes a one-minute question instead of speculation.

The ==🟢app-level observer with descendant-filtering callback== pattern is reusable for any app where you want to react to internal state changes without plumbing through the input layer. And the ==🟢non-intercepting eventtap-as-signal== pattern (tap returns `false`, stamps a flag in module state) is the safe way to mix in keystroke information when the AX layer doesn't have the distinctions you need — without tripping the "silent write success" class of bugs the write-mode taps ran into.
