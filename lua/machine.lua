-- Which Mac stepper runs on, so each Mac keeps its own layouts, screen memory, live hotkeys and logs.
-- Two Macs run stepper from this one Dropbox folder since 2026-10-14 (fleet F045, the Mac mini), and
-- on its first evening the mini's one-display layout overwrote the MacBook's "native" one (both call
-- a single display "native"). fleet F040/well-kept-logs has the rule: what describes one Mac stays
-- that Mac's. ~/.config/fleet/machine-tag, written on each Mac and never synced, names any Mac but
-- the MacBook ("mini"); no file means the MacBook, whose files keep their old place in data/.
-- Shared settings (bear-notes.jsonc, hyper-actions.jsonc) stay in data/ for every Mac.
local M = {}

local f = io.open(os.getenv("HOME") .. "/.config/fleet/machine-tag", "r")
M.tag = f and ((f:read("l") or ""):match("^%s*([%w-]*)")) or ""
if f then f:close() end
M.primary = (M.tag == "")

-- data/ on the MacBook, data/<tag>/ on any other Mac (made on first use)
function M.dataDir(dataRoot)
  if M.primary then return dataRoot end
  local dir = dataRoot .. M.tag .. "/"
  hs.fs.mkdir(dir)
  return dir
end

return M
