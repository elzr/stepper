require("hs.ipc")  -- Enable CLI control first
-- A reload freezes input for a few seconds, so say so first. Everything below loads on a
-- timer: the main thread draws nothing while a load runs, so a notice shown and then
-- followed straight by the load would only appear once it was over. hsLoaded is set at the
-- end, for hs-reload.sh to wait on.
hsLoaded = false
local loadStarted = hs.timer.secondsSinceEpoch()
local reloadNotice = hs.alert.show("⟳ Hammerspoon reloading · input may lag a few seconds", 60)
hs.timer.doAfter(0.1, function()
require("rcmd")
-- The tablogs' live now/ pages (reading F030-tablogs): Chrome's and Safari's watchers, and
-- Safari kept running, hidden. pcall: it can't stop stepper from loading.
local ok, err = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/reading/features/F030-tablogs/tablogs-now.lua")
if not ok then print("tablogs-now.lua: " .. tostring(err)) end
-- reading F031 readwise-reader-integration: the launcher's "↻ Sync" (reading/subprojects/launcher, a PUT of
-- refresh-request) runs update-csv.py through this watcher. pcall, as above.
local okRW, errRW = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/reading/features/F031-readwise-reader-integration/readwise-sync.lua")
if okRW then readwiseSync = errRW else print("readwise-sync.lua: " .. tostring(errRW)) end
-- products bifocals L002-readwise: bifocals.internal/readwise/<id> PUTs <id>.request and this
-- watcher writes Readwise Reader's copy of the document for it to read. pcall, as above.
local okRC, errRC = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/products/subprojects/bifocals/features/L002-readwise/readwise-copy.lua")
if okRC then readwiseCopy = errRC else print("readwise-copy.lua: " .. tostring(errRC)) end
-- fleet F044/ironing-out-clipboard-kinks: re-point Paste's clipboard links out of its sandbox,
-- so CleanShot opens them without Full Disk Access, and swap TIFF/HEIC image copies for PNGs.
-- pcall: it can't stop stepper from loading.
local okCP, errCP = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F044-security-mindset/subfeatures/ironing-out-clipboard-kinks/clipboard-kinks.lua")
if not okCP then print("clipboard-kinks.lua: " .. tostring(errCP)) end
-- fleet F029/image-stream-introspection: rebuilds the Paste stream whenever Paste's database
-- changes, so the image wall is live. pcall, as above.
local okIS, errIS = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F029-rhys-rsi-recursive-self-improvement/subfeatures/image-stream-introspection/live.lua")
if not okIS then print("live.lua: " .. tostring(errIS)) end
-- fleet F042-webcams-as-magic-windows: re-signs the iPhone app before its 7-day free signing
-- runs out, installing over Wi-Fi. pcall, as above.
local okMW, errMW = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F042-webcams-as-magic-windows/ios/resign.lua")
if not okMW then print("resign.lua: " .. tostring(errMW)) end
-- fleet F040/claude-introspection/token-metrics: the week's two reports, written by a headless
-- Claude half an hour before the weekly reset (weekly.py, weekly.md). pcall, as above.
local okTM, errTM = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F040-tiptop-software-infrastructure/subfeatures/claude-introspection/subfeatures/token-metrics/weekly.lua")
if not okTM then print("token-metrics weekly.lua: " .. tostring(errTM)) end
-- fleet F043 Bear-hands: the Bear customizations (the week's note names, image thumbnails,
-- auto-pagination). Before stepper, whose bear-hud binds the note hotkeys to this week's names.
-- pcall: it can't stop stepper from loading.
local okBear, errBear = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F043-Bear-hands/bear.lua")
if not okBear then print("bear.lua: " .. tostring(errBear)) end
-- stepper's error still reaches the console, raised again after the notice says so
local okStep, errStep = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/lua/stepper.lua")
hs.alert.closeSpecific(reloadNotice)
hsLoaded = true
if not okStep then
  hs.alert.show("Hammerspoon: stepper.lua failed to load · see the console", 6)
  error(errStep)
end
-- fleet F041/UI-peripherals: the Wacom's leftmost ExpressKey (⌃⌥⇧A) turns Presentify on and off.
-- After stepper: stepper.lua deletes every hotkey that exists when it loads.
local okWP, errWP = pcall(dofile, "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F041-happy-hardware/subfeatures/UI-peripherals/wacom-presentify.lua")
if not okWP then print("wacom-presentify.lua: " .. tostring(errWP)) end
hsLoadSeconds = hs.timer.secondsSinceEpoch() - loadStarted
hs.alert.show(string.format("Hammerspoon ready · %.1f s", hsLoadSeconds), 1.5)
end)
