-- ~/.hammerspoon/init.lua is a COPY of this file (install: bin/install-bootstrap.sh), never a symlink:
-- it stays a plain local file so Hammerspoon starts even when Dropbox doesn't answer, as in the
-- May–June 2026 snafu. hs.ipc comes first, so ~/bin/hs-reload.sh always works; then the real init,
-- hammerspoon-init.lua in stepper's Dropbox folder. When that folder can't be read, or the switch
-- ~/.config/fleet/stepper-from-local-copy exists, stepper runs instead from the last copy that loaded
-- cleanly, which every good load refreshes in ~/.local/share/stepper-lkg/ (fleet F039/taming-Dropbox).
require("hs.ipc")  -- Enable CLI control first
local HOME = os.getenv("HOME")
local STEPPER = "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/"
local LKG = HOME .. "/.local/share/stepper-lkg/"
local SWITCH = HOME .. "/.config/fleet/stepper-from-local-copy"

-- stat only: it never makes a Dropbox placeholder download on the main thread
local forced = hs.fs.attributes(SWITCH) ~= nil
local reachable = hs.fs.attributes(STEPPER .. "hammerspoon-init.lua") ~= nil
  and hs.fs.attributes(STEPPER .. "lua/stepper.lua") ~= nil

if reachable and not forced then
  local ok, err = pcall(dofile, STEPPER .. "hammerspoon-init.lua")
  if ok then
    -- Once stepper has loaded cleanly, copy what it runs on, in the background (rsync only sends
    -- what changed). A load that failed leaves the last good copy alone.
    stepperLkgWait = hs.timer.waitUntil(function() return hsLoaded end, function()
      if not stepperLoaded then return end
      hs.fs.mkdir(HOME .. "/.local/share")
      hs.fs.mkdir(LKG)
      stepperLkgCopy = hs.task.new("/usr/bin/rsync", function(code, _, stdErr)
        if code ~= 0 then print("[stepper-lkg] rsync exited " .. code .. ": " .. stdErr) end
      end, { "-aR", "--delete",
        "--exclude", "data/app-icons/", "--exclude", "data/cmd-tab-samples/", "--exclude", "data/layout-backups/",
        "lua", "data", "Spoons", "features/F010-sync-display-names-in-Lunar", LKG })
      stepperLkgCopy:setWorkingDirectory(STEPPER)
      stepperLkgCopy:start()
      -- this file is installed by copy: say so when the installed one has fallen behind the repo's
      stepperBootstrapCmp = hs.task.new("/usr/bin/cmp", function(code)
        if code == 1 then print("[stepper-lkg] ~/.hammerspoon/init.lua differs from stepper's bootstrap-init.lua: run bin/install-bootstrap.sh") end
      end, { "-s", HOME .. "/.hammerspoon/init.lua", STEPPER .. "bootstrap-init.lua" })
      stepperBootstrapCmp:start()
    end, 0.5)
    return
  end
  print("hammerspoon-init.lua: " .. tostring(err))
end

-- From the local copy: stepper and rcmd only, since everything else lives in Dropbox
local why = forced and "the switch is on" or "Dropbox can't be read"
stepperFromLocalCopy = true
hsLoaded = false
if not hs.fs.attributes(LKG .. "lua/stepper.lua") then
  hsLoaded = true
  hs.alert.show("Hammerspoon: stepper can't load (" .. why .. ") and has no local copy yet", 10)
  return
end
package.path = LKG .. "Spoons/?.spoon/init.lua;" .. package.path  -- WinWin from the copy
local loadStarted = hs.timer.secondsSinceEpoch()
local notice = hs.alert.show("⟳ Hammerspoon: stepper from its local copy (" .. why .. ")", 60)
hs.timer.doAfter(0.1, function()
  local okRcmd, errRcmd = pcall(require, "rcmd")
  if not okRcmd then print("rcmd: " .. tostring(errRcmd)) end
  local okStep, errStep = pcall(dofile, LKG .. "lua/stepper.lua")
  hs.alert.closeSpecific(notice)
  stepperLoaded = okStep
  hsLoadSeconds = hs.timer.secondsSinceEpoch() - loadStarted
  hsLoaded = true
  if not okStep then
    hs.alert.show("Hammerspoon: stepper's local copy failed to load too · see the console", 8)
    error(errStep)
  end
  hs.alert.show("Hammerspoon ready · stepper from its local copy (" .. why .. ")", 4)
end)
