# Layout saves read windows off the main thread

**Date**: 2026-10-09

The [lost key-up case study](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/case-studies/2026-10-09-lost-key-up-walked-note-down.md) ended on this: ==🔴macOS drops a hotkey's release when Hammerspoon's main thread is busy==, and the per-minute layout save kept it busy. The save read every window through Accessibility on the thread stepper's hotkeys run on, so an app slow to answer held the hotkeys for as long as it took, up to 6 s per call. ==🟢Now a helper process reads the windows, and the main thread only files the result: 6–12 ms a save instead of about 200, and no longer when an app is busy.== The user has bigger plans for the saves, so they had to get cheap first.

## Contents

- [What changed](#what-changed)
- [Measured](#measured)
- [Gotchas for what comes next](#gotchas-for-what-comes-next)

## What changed

- ==🟢[layoutsnap.swift](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layoutsnap.swift)== reads the windows `hs.window.orderedWindows()` returns (on screen, not minimized, unhidden regular apps, front to back) in its own process. It reads apps in parallel, with one Accessibility round trip per window, and waits at most 1 s per call. [layout.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/layout.lua) builds it with `swiftc` on first use, like inputprobe, and starts one per save through `hs.task`, which lends it Hammerspoon's Accessibility grant.
- ==🟢An app that doesn't answer keeps its last saved windows== (`save-kept` in the log) instead of dropping out of the file, which is what happened before, after the main thread had waited for it.
- ==🔵One read per save.== A periodic save used to sweep the windows three times: autosave's zero-window check, the save itself, and screenmemory's window-id lookup. The snapshot now serves all three.
- ==🔵Nothing written when nothing changed.== No file write, ring copy or log lines. The 10-minute ring copies only after a save changed something, so an idle desk doesn't push older layouts out.
- **The save before sleep** still reads in Hammerspoon (`layout.autoSave({now = true})` in [stepper.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua)): a helper still running when the system sleeps would finish after the wake, when macOS may have moved windows. Nobody is typing then.
- **If the helper can't be built or run**, saves read the windows in Hammerspoon as before, and the console says why once.
- **[screenmemory.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/screenmemory.lua)** stores its memory flat (`"App\nTitle\nscreen": "x y w h ts"`) and keeps each app's newest 200 titles. ==🔴It used to take 8.7 s to load at every reload==: the 811 KB file held one small object per window and screen, and `hs.json.decode` slows with the square of their number. A do-done tab with a clock in its title added a Chrome title every minute (1,401 of them). The first load migrated the old file; all 1,094 surviving entries matched it exactly, and only Chrome and kitty lost titles.
- `layout.saveStats()` reports, over IPC, how saves went since load and what they cost the main thread.

## Measured

23 windows on quad-32, every app answering unless noted.

| | Before | After |
|---|---|---|
| Main thread per save | one window sweep 66 ms + per-window reads 38 ms (~9 calls a window) + `mkdir` shell 5.5 ms; ==🔴three sweeps per periodic save== | ==🟢5.8–11.8 ms==: launch 1 ms, decode 2.7 ms, entries 2 ms, encode 1 ms, compare and write |
| Reading the windows | on the main thread | ==🟢130–190 ms in the helper's own process== |
| One app not answering (Calendar paused with `SIGSTOP`) | main thread waits up to 6 s per call, then drops the app's windows | helper 1,092 ms, main thread 29.8 ms, Calendar's window kept |
| Screen memory after a save | 811 KB rewritten 5 s later, 52 ms to encode | 118 KB |
| Screen memory at reload | ==🔴8.7 s== (8 s in the 19:04 reload's console) | ==🟢within the same second== |
| Parity | | the same windows, order and fields as `hs.window.orderedWindows()`; 22 of 23 entries identical to the old code's last save, the 23rd a do-done title that had moved on |

==🟣Most minutes still write==: the do-done tab's title carries the time, so the layout changes every minute it's on screen. Dropping the time from that title would make idle minutes free.

## Gotchas for what comes next

- ==🔴`hs.json.decode` is quadratic in same-sized objects.== LuaSkin hashes each container it converts, and an `NSDictionary` hashes by its count, so thousands of `{x, y, w, h}` objects all collide: 400 took 311 ms, the same data as 400 strings 4.7 ms. Keep any file that grows (a layout history, say) flat, or in lines.
- ==🔵`hs.json.encode`'s key order changes at every reload==: Lua seeds its string hashes per state. Within a session the same layout encodes the same, so the first save after a reload always writes.
- Anything that reads windows through Accessibility on Hammerspoon's main thread can stall the hotkeys for seconds. Restore, the drift check after a wake and the retry still do, but only right after screen changes and wakes.
