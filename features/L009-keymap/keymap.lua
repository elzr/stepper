-- =============================================================================
-- L009-keymap: visual map of all keyboard shortcuts
-- =============================================================================
-- Reads rcmd plist + (later) stepper hyper configs + notes.jsonc, generates
-- keymap.html. Phase 1: rcmd only, basic keyboard render.

local M = {}
M._watchers = {}  -- module-scope, prevents pathwatcher GC (per L005 lesson)

local projectRoot = nil
local featureDir = nil
local outputFile = nil

local RCMD_PLIST = os.getenv("HOME") ..
  "/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist"

-- =============================================================================
-- Keyboard layout: MacBook Pro M1 Max US English
-- =============================================================================
-- Per-row entries are keys (or arrow-stack containers).
--   id          : stable id, matched against rcmd.key (lowercase letter/digit) and notes
--   label       : main label (rendered larger; for two-row keys, sits at the bottom)
--   altLabel    : secondary label (smaller, sits ABOVE the main label) — e.g. shift-symbol
--                 for digits/punctuation, or remap behavior for caps lock
--   symbol      : modifier glyph (rendered big in top-right; pairs with `label` bottom-right)
--   iconLabel   : function-key icon, rendered big and centered
--   cornerLabel : tiny label in top-left corner (used for F-key labels alongside iconLabel)
--   class       : extra CSS class
--   w           : flex-grow weight (default 1)
--   kind="arrow-stack", subKeys={...} : two stacked half-height keys (up/down)

local KEYBOARD = {
  { class = "func-row", keys = {
    {id="esc",  label="esc"},
    {id="f1",   cornerLabel="F1",  iconLabel="🔅", class="func"},  -- brightness down
    {id="f2",   cornerLabel="F2",  iconLabel="🔆", class="func"},  -- brightness up
    {id="f3",   cornerLabel="F3",  iconLabel="▦",  class="func"},  -- mission control
    {id="f4",   cornerLabel="F4",  iconLabel="🔍", class="func"},  -- spotlight
    {id="f5",   cornerLabel="F5",  iconLabel="🎤", class="func"},  -- dictation
    {id="f6",   cornerLabel="F6",  iconLabel="🌙", class="func"},  -- focus / DND
    {id="f7",   cornerLabel="F7",  iconLabel="⏮", class="func"},
    {id="f8",   cornerLabel="F8",  iconLabel="⏯", class="func"},
    {id="f9",   cornerLabel="F9",  iconLabel="⏭", class="func"},
    {id="f10",  cornerLabel="F10", iconLabel="🔇", class="func"},
    {id="f11",  cornerLabel="F11", iconLabel="🔉", class="func"},
    {id="f12",  cornerLabel="F12", iconLabel="🔊", class="func"},
    {id="touchid", label="⏻", class="touchid"},
  }},
  { class = "digit-row", keys = {
    {id="`",  label="`", altLabel="~"},
    {id="1",  label="1", altLabel="!"},  {id="2",  label="2", altLabel="@"},
    {id="3",  label="3", altLabel="#"},  {id="4",  label="4", altLabel="$"},
    {id="5",  label="5", altLabel="%"},  {id="6",  label="6", altLabel="^"},
    {id="7",  label="7", altLabel="&"},  {id="8",  label="8", altLabel="*"},
    {id="9",  label="9", altLabel="("},  {id="0",  label="0", altLabel=")"},
    {id="-",  label="-", altLabel="_"},  {id="=",  label="=", altLabel="+"},
    {id="delete", label="delete", symbol="⌫", class="wide", w=1.5},
  }},
  { class = "tab-row", keys = {
    {id="tab", label="tab", symbol="⇥", class="wide", w=1.5},
    {id="q", label="Q"}, {id="w", label="W"}, {id="e", label="E"},
    {id="r", label="R"}, {id="t", label="T"}, {id="y", label="Y"},
    {id="u", label="U"}, {id="i", label="I"}, {id="o", label="O"},
    {id="p", label="P"},
    {id="[",  label="[", altLabel="{"},
    {id="]",  label="]", altLabel="}"},
    {id="\\", label="\\", altLabel="|"},
  }},
  { class = "caps-row", keys = {
    {id="caps", label="⇪ caps", altLabel="esc / ◆hyper", class="wide caps tinted", w=1.75},
    {id="a", label="A"}, {id="s", label="S"}, {id="d", label="D"},
    {id="f", label="F"}, {id="g", label="G"}, {id="h", label="H"},
    {id="j", label="J"}, {id="k", label="K"}, {id="l", label="L"},
    {id=";", label=";", altLabel=":"},
    {id="'", label="'", altLabel='"'},
    {id="return", label="return", symbol="⏎", class="wide", w=1.75},
  }},
  { class = "shift-row", keys = {
    {id="shift-l", label="shift", symbol="⇧", class="wide mod tinted", w=2.25},
    {id="z", label="Z"}, {id="x", label="X"}, {id="c", label="C"},
    {id="v", label="V"}, {id="b", label="B"}, {id="n", label="N"},
    {id="m", label="M"},
    {id=",", label=",", altLabel="<"},
    {id=".", label=".", altLabel=">"},
    {id="/", label="/", altLabel="?"},
    {id="shift-r", label="shift", symbol="⇧", class="wide mod tinted", w=2.75},
  }},
  -- M1 Max MBP: NO right-control. fn, ctrl, opt, cmd | space | cmd, opt, arrows.
  { class = "mod-row", keys = {
    {id="fn",    label="fn",                  class="wide mod tinted"},
    {id="ctrl",  label="control", symbol="⌃", class="wide mod tinted"},
    {id="opt-l", label="option",  symbol="⌥", class="wide mod tinted"},
    {id="cmd-l", label="command", symbol="⌘", class="wide mod tinted"},
    {id="space", label="",                    class="space", w=5},
    {id="cmd-r", label="r⌘", symbol="⌘", class="wide mod tinted"},
    {id="opt-r", label="r⌥", symbol="⌥", class="wide mod tinted"},
    {id="left",  label="◀", class="arrow half-bottom"},
    {kind="arrow-stack", subKeys={
      {id="up",   label="▲", class="arrow half"},
      {id="down", label="▼", class="arrow half"},
    }},
    {id="right", label="▶", class="arrow half-bottom"},
  }},
}

-- =============================================================================
-- File IO
-- =============================================================================

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function writeFile(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function htmlEscape(s)
  if s == nil then return "" end
  return tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                   :gsub('"', "&quot;"):gsub("'", "&#39;")
end

local function stripJsoncComments(content)
  -- Strip // line comments. Two passes:
  --   1. Full-line comments (incl. file-leading) — match \n then optional indent then //
  --      Prepended \n lets the first line match too, then sub(2) drops it.
  --   2. Trailing inline comments — require non-':' before // so URLs survive.
  local s = (("\n" .. content):gsub("\n[ \t]*//[^\n]*", ""))
  s = (s:gsub("([^:])//[^\n]*", "%1"))
  return s:sub(2)
end

-- =============================================================================
-- Data sources
-- =============================================================================

-- Read rcmd's appKeyAssignments. Returns map keyed by lowercase letter/digit.
local function readRcmd()
  local plist = hs.plist.read(RCMD_PLIST)
  if not plist then
    print("[keymap] Failed to read rcmd plist at " .. RCMD_PLIST)
    return {}
  end
  local out = {}
  local assignments = plist.appKeyAssignments or {}
  for _, entryStr in ipairs(assignments) do
    local entry = hs.json.decode(entryStr)
    if entry and entry.key and entry.app and entry.app.originalName then
      local k = tostring(entry.key):lower()
      out[k] = {
        app = entry.app.originalName,
        path = entry.app.path,
        bundleID = entry.app.identifier and entry.app.identifier:gsub(":%d+$", ""),
        whenFocusedAction = entry.whenAlreadyFocusedAction,
      }
    else
      print("[keymap] Skipped malformed rcmd entry")
    end
  end
  return out
end

local function readNotesJsonc()
  local content = readFile(featureDir .. "/notes.jsonc")
  if not content then return {} end
  local data = hs.json.decode(stripJsoncComments(content)) or {}
  return data
end

-- Read all 3 stepper-hyper sources (bear-notes.jsonc, live-toggle-hotkeys.json,
-- hyper-actions.jsonc) and return two maps:
--   hyper : keys with the hyper modifier (◆) — the stepper-managed layer
--   other : keys that Stepper binds with non-hyper modifiers (e.g. scoped Sheets ⌃⌘arrows)
-- Both maps key by lowercase id matching the keyboard layout.
local function readHyperConfigs()
  local hyper, other = {}, {}

  -- 1. bear-notes.jsonc — notes + urls + reservedKeys (live-toggle slot stubs)
  local notesPath = projectRoot .. "data/bear-notes.jsonc"
  local content = readFile(notesPath)
  if content then
    local config = hs.json.decode(stripJsoncComments(content))
    if config then
      local vars = config.vars or {}
      local function expand(s)
        if not s then return nil end
        for varName, varValue in pairs(vars) do
          s = (s:gsub("%${" .. varName .. "}", varValue))
        end
        return s
      end
      for _, note in ipairs(config.notes or {}) do
        local k = note.key:lower()
        hyper[k] = {
          type = "bear-note",
          title = expand(note.title),
          pastTitle = expand(note.pastTitle),
          nextTitle = expand(note.nextTitle),
          source = "bear-notes.jsonc",
        }
      end
      for _, entry in ipairs(config.urls or {}) do
        local k = entry.key:lower()
        hyper[k] = {
          type = "url",
          url = entry.url,
          source = "bear-notes.jsonc",
        }
      end
      -- reservedKeys: single-char strings reserve hyper slots for live-toggle
      for _, k in ipairs(config.reservedKeys or {}) do
        if type(k) == "string" and #k == 1 then
          local lk = k:lower()
          hyper[lk] = hyper[lk] or {
            type = "live-toggle-slot",
            title = nil,
            source = "bear-notes.jsonc (reservedKeys)",
          }
        end
      end
    end
  end

  -- 2. live-toggle-hotkeys.json — fills in titles for the X/Q/A/Z slots
  local livePath = projectRoot .. "data/live-toggle-hotkeys.json"
  local liveContent = readFile(livePath)
  if liveContent and #liveContent > 0 then
    local liveData = hs.json.decode(liveContent) or {}
    for k, slot in pairs(liveData) do
      if type(k) == "string" then
        local lk = k:lower()
        hyper[lk] = {
          type = "live-toggle",
          title = slot.title,
          bundleID = slot.bundleID,
          source = "live-toggle-hotkeys.json",
        }
      end
    end
  end

  -- 3. hyper-actions.jsonc — global hyper actions + scoped (other) actions
  local actionsPath = projectRoot .. "data/hyper-actions.jsonc"
  local actionsContent = readFile(actionsPath)
  if actionsContent then
    local actions = hs.json.decode(stripJsoncComments(actionsContent))
    if actions then
      for _, act in ipairs(actions) do
        local k = act.key:lower()
        local desc
        if act.action == "keystroke" then
          local ks = act.keystroke or {}
          desc = string.format("→ %s%s",
            table.concat(ks.mods or {}, ""), ks.key or "?")
        elseif act.action == "keystroke-sequence" then
          local seq = {}
          for _, s in ipairs(act.sequence or {}) do table.insert(seq, s.key) end
          desc = "→ " .. table.concat(seq, " ")
        else
          desc = act.action or "?"
        end
        local entry = {
          type = "action",
          description = desc,
          mods = act.mods,
          scope = act.scope and act.scope.titleContains,
          source = "hyper-actions.jsonc",
        }
        if act.mods and #act.mods > 0 then
          other[k] = entry  -- non-hyper modifier (e.g. ctrl+cmd)
        else
          hyper[k] = entry
        end
      end
    end
  end

  return hyper, other
end

-- Build a friendly action label for the bindings table (per layer entry shape)
local function hyperActionLabel(b)
  if b.type == "bear-note" then return b.title or "(untitled)" end
  if b.type == "url" then return b.url end
  if b.type == "live-toggle" then
    return string.format("live: %s", b.title or "(unset)")
  end
  if b.type == "live-toggle-slot" then
    return "live: (unset — assign with R⌥+◆key)"
  end
  if b.type == "action" then return b.description end
  return "?"
end

-- Build a per-layer "notes" snippet (used until notes.jsonc merges in Phase 3)
local function hyperNotesSnippet(b)
  if b.type == "bear-note" and (b.pastTitle or b.nextTitle) then
    return string.format("R⌘ → %s · R⌥ → %s",
      b.pastTitle or "—", b.nextTitle or "—")
  end
  if b.type == "action" and b.scope then
    return string.format("scoped: window title contains '%s'", b.scope)
  end
  return ""
end

-- Symbol map for modifier keys (used in the Modifier column of the bindings table)
local MOD_SYMBOLS = { ctrl = "⌃", cmd = "⌘", alt = "⌥", shift = "⇧" }
local KEY_DISPLAY = {
  left = "←", right = "→", up = "↑", down = "↓",
  ["return"] = "⏎", tab = "⇥", delete = "⌫", space = "␣",
}
local function displayKey(k)
  return KEY_DISPLAY[k:lower()] or k:upper()
end
local function modString(mods)
  local out = ""
  for _, m in ipairs(mods or {}) do out = out .. (MOD_SYMBOLS[m] or m) end
  return out
end

-- True when mods is exactly {ctrl, alt, shift, cmd} (hyper). Used for ◆ marker.
local function isHyperMods(mods)
  if not mods or #mods ~= 4 then return false end
  local set = {}
  for _, m in ipairs(mods) do set[m] = true end
  return set.ctrl and set.alt and set.shift and set.cmd
end

-- Parse a chord like "F12", "cmd+\\", "hyper+1" into key + expanded mods.
-- "hyper" expands to {ctrl, alt, shift, cmd}.
local function parseChord(chord)
  local parts = {}
  for p in chord:gmatch("[^+]+") do table.insert(parts, p) end
  if #parts == 0 then return nil, nil end
  local key = parts[#parts]:lower()
  local mods = {}
  for i = 1, #parts - 1 do
    local m = parts[i]:lower()
    if m == "hyper" then
      table.insert(mods, "ctrl"); table.insert(mods, "alt")
      table.insert(mods, "shift"); table.insert(mods, "cmd")
    else
      table.insert(mods, m)
    end
  end
  return key, mods
end

-- Merge annotations from notes.jsonc into rcmd / hyper / other (in place).
-- For rcmd / hyper: enrich existing entries.
-- For other: ADD entries (since "other" is largely user-managed).
local function mergeAnnotations(rcmd, hyper, other, notes)
  for k, ann in pairs(notes.rcmd or {}) do
    local target = rcmd[k] or {}  -- annotation may name an unbound key (drift case)
    target.mnemonic    = ann.mnemonic
    target.bearNote    = ann.bearNote
    target.note        = ann.note
    target.expectedApp = ann.expectedApp
    target._annotated  = true
    rcmd[k] = target
  end
  for k, ann in pairs(notes.hyper or {}) do
    local target = hyper[k] or {}
    target.mnemonic   = ann.mnemonic
    target.bearNote   = ann.bearNote
    target.note       = ann.note
    target._annotated = true
    hyper[k] = target
  end
  for chord, ann in pairs(notes.other or {}) do
    local key, mods = parseChord(chord)
    if key then
      other[key] = other[key] or {type = "manual"}
      other[key].label    = ann.label
      other[key].bearNote = ann.bearNote
      other[key].note     = ann.note
      other[key].tool     = ann.tool
      other[key].chord    = chord
      other[key].mods     = mods
      other[key]._annotated = true
    end
  end
end

-- Drift detection: annotation says X but reality says Y (or nothing)
local function computeWarnings(rcmd, hyper, notes)
  local warnings = {}
  for k, ann in pairs(notes.rcmd or {}) do
    if ann.expectedApp then
      local actual = rcmd[k] and rcmd[k].app
      if not actual then
        table.insert(warnings, {
          key = k, layer = "rcmd",
          message = string.format("annotated as '%s' but rcmd no longer binds %s",
            ann.expectedApp, k:upper()),
        })
      elseif not actual:lower():find(ann.expectedApp:lower(), 1, true) then
        table.insert(warnings, {
          key = k, layer = "rcmd",
          message = string.format("expected '%s', got '%s'", ann.expectedApp, actual),
        })
      end
    end
  end
  for k, _ in pairs(notes.hyper or {}) do
    if not (hyper[k] and hyper[k].type) then
      table.insert(warnings, {
        key = k, layer = "hyper",
        message = string.format("annotated but no hyper binding on %s", k:upper()),
      })
    end
  end
  return warnings
end

-- Mini markdown: **bold**, *italic*, [text](url), [[wikilink]] → bear:// URL
local function renderMarkdown(s)
  if not s or s == "" then return "" end
  -- Process wikilinks BEFORE escape so the [[ ]] survive
  local out = s:gsub("%[%[([^%]]+)%]%]", function(title)
    local encoded = (title:gsub(" ", "%%20"))
    return string.format('<a href="bear://x-callback-url/open-note?title=%s">%s</a>',
      encoded, htmlEscape(title))
  end)
  -- Plain markdown links
  out = out:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(text, url)
    return string.format('<a href="%s">%s</a>', url, htmlEscape(text))
  end)
  -- Bold and italic (very simple)
  out = out:gsub("%*%*([^%*]+)%*%*", "<strong>%1</strong>")
  out = out:gsub("%*([^%*]+)%*", "<em>%1</em>")
  return out
end

-- Render mnemonic with ~tildes~ around the underlined letter.
-- "c~A~lendar" → "c<u>A</u>lendar"
local function renderMnemonic(s)
  if not s then return nil end
  local escaped = htmlEscape(s)
  return (escaped:gsub("~([^~]+)~", "<u>%1</u>"))
end

-- Render an inline bearNote wikilink as a clickable bear:// chip
local function renderBearNoteChip(s)
  if not s or s == "" then return "" end
  local title = s:match("^%[%[(.-)%]%]$") or s
  local encoded = (title:gsub(" ", "%%20"))
  return string.format(
    ' <a class="bearchip" href="bear://x-callback-url/open-note?title=%s">%s</a>',
    encoded, htmlEscape(title))
end

-- =============================================================================
-- HTML rendering
-- =============================================================================

-- Render one key tile. `layers` is a map { rcmd=label, hyper=label, other=label,
-- hyperMod=bool, warn=string }.
local function renderKeyTile(key, layers)
  layers = layers or {}
  local classes = {"key"}
  if key.class then table.insert(classes, key.class) end
  if layers.rcmd  then table.insert(classes, "has-rcmd")  end
  if layers.hyper then table.insert(classes, "has-hyper") end
  if layers.other then table.insert(classes, "has-other") end
  if layers.warn  then table.insert(classes, "has-warn")  end

  local style = ""
  if key.w and key.w ~= 1 then
    style = string.format(' style="flex-grow:%g"', key.w)
  end

  -- ◆ removed from keymap tiles — the blue underline already signals hyper.

  local warnDot = layers.warn
    and string.format('<span class="warn-dot" title="%s"></span>', htmlEscape(layers.warn))
    or ""

  -- Primary layer (rcmd > hyper > other priority) becomes the bottom border.
  -- Remaining layers stack as colored underlines above the border.
  local activeLayers = {}
  if layers.rcmd  then table.insert(activeLayers, "rcmd")  end
  if layers.hyper then table.insert(activeLayers, "hyper") end
  if layers.other then table.insert(activeLayers, "other") end

  local underlines = {}
  if #activeLayers >= 1 then
    table.insert(classes, "border-" .. activeLayers[1])
    table.insert(classes, "layers-" .. #activeLayers)
    for i = 2, #activeLayers do
      local slot = i - 1  -- 1st extra → slot-1 (lower), 2nd extra → slot-2 (higher)
      table.insert(underlines, string.format('<span class="under slot-%d %s"></span>',
        slot, activeLayers[i]))
    end
  end

  -- Pick rendering style based on which fields are present
  local content
  if key.iconLabel then
    -- Function-key style: icon on top (smaller), F-label below
    content = string.format(
      '<span class="icon">%s</span><span class="corner">%s</span>',
      htmlEscape(key.iconLabel), htmlEscape(key.cornerLabel or ""))
    table.insert(classes, "style-func")
  elseif key.symbol then
    -- Modifier style: big symbol top-right, small label bottom-right
    content = string.format(
      '<span class="symbol">%s</span><span class="modlabel">%s</span>',
      htmlEscape(key.symbol), htmlEscape(key.label or ""))
    table.insert(classes, "style-mod")
  elseif key.altLabel then
    -- Two-row: altLabel small on top, label larger on bottom
    content = string.format(
      '<span class="alt">%s</span><span class="main">%s</span>',
      htmlEscape(key.altLabel), htmlEscape(key.label))
    table.insert(classes, "style-dual")
  else
    -- Plain centered label
    content = string.format('<span class="label">%s</span>', htmlEscape(key.label or ""))
    table.insert(classes, "style-plain")
  end

  return string.format(
    '<div class="%s" data-key="%s"%s>%s%s%s</div>',
    table.concat(classes, " "),
    htmlEscape(key.id),
    style,
    content,
    warnDot,
    table.concat(underlines, "")
  )
end

-- Render a key OR an arrow-stack container.
local function renderKeyOrStack(key, getLayers)
  if key.kind == "arrow-stack" then
    local sub = {}
    for _, sk in ipairs(key.subKeys) do
      table.insert(sub, renderKeyTile(sk, getLayers(sk.id)))
    end
    return '<div class="arrow-stack">' .. table.concat(sub, "") .. '</div>'
  end
  return renderKeyTile(key, getLayers(key.id))
end

local function renderKeyboard(rcmd, hyper, other, warningsByKey)
  local function getLayers(keyId)
    local layers = {}
    if rcmd[keyId]  and rcmd[keyId].app   then layers.rcmd  = rcmd[keyId].app end
    if hyper[keyId] and hyper[keyId].type then
      layers.hyper = hyperActionLabel(hyper[keyId])
      layers.hyperMod = true
    end
    if other[keyId] then
      layers.other = other[keyId].label or other[keyId].description or "?"
      if isHyperMods(other[keyId].mods) then layers.hyperMod = true end
    end
    if warningsByKey[keyId] then layers.warn = warningsByKey[keyId] end
    return layers
  end

  local rows = {}
  for _, row in ipairs(KEYBOARD) do
    local tiles = {}
    for _, key in ipairs(row.keys) do
      table.insert(tiles, renderKeyOrStack(key, getLayers))
    end
    table.insert(rows, string.format('<div class="row %s">%s</div>', row.class, table.concat(tiles, "")))
  end
  return string.format('<div class="kb">%s</div>', table.concat(rows, "\n"))
end

local function renderBindings(rcmd, hyper, other)
  -- Build a flat list of binding rows from all 3 layers.
  -- actionHtml/notesHtml are pre-rendered (markdown, mnemonic, bear chip).
  local list = {}

  for k, b in pairs(rcmd) do
    if b.app or b._annotated then  -- skip annotation-only entries with no actual binding
      local label = renderMnemonic(b.mnemonic) or htmlEscape(b.app or "(unbound)")
      table.insert(list, {
        key = k, layer = "rcmd",
        modifierHtml = '<span class="mod-sym rcmd">r⌥</span>' .. htmlEscape(displayKey(k)),
        actionHtml = label .. (b.app and "" or ' <span class="muted">(unbound)</span>'),
        notesHtml = renderMarkdown(b.note) .. renderBearNoteChip(b.bearNote),
      })
    end
  end

  for k, b in pairs(hyper) do
    if b.type then
      local primary = hyperActionLabel(b)
      local label = renderMnemonic(b.mnemonic) or htmlEscape(primary)
      local extras = hyperNotesSnippet(b)
      local notes = renderMarkdown(b.note)
      if extras ~= "" then notes = notes .. (notes ~= "" and "<br>" or "") .. htmlEscape(extras) end
      notes = notes .. renderBearNoteChip(b.bearNote)
      table.insert(list, {
        key = k, layer = "hyper",
        modifierHtml = '<span class="mod-sym hyper">◆</span>' .. htmlEscape(displayKey(k)),
        actionHtml = label,
        notesHtml = notes,
      })
    end
  end

  for k, b in pairs(other) do
    -- Hyper-equivalent mods collapse to ◆ for compactness
    local modText = isHyperMods(b.mods) and "◆" or modString(b.mods)
    local action = b.label or b.description or "(unknown)"
    local notes = renderMarkdown(b.note)
    if b.scope then
      notes = notes .. (notes ~= "" and "<br>" or "") ..
        string.format("scoped: window title contains <code>%s</code>", htmlEscape(b.scope))
    end
    if b.tool then
      notes = notes .. (notes ~= "" and " · " or "") ..
        string.format('<span class="tool">%s</span>', htmlEscape(b.tool))
    end
    notes = notes .. renderBearNoteChip(b.bearNote)
    table.insert(list, {
      key = k, layer = "other",
      modifierHtml = '<span class="mod-sym other">' .. htmlEscape(modText) .. '</span>' .. htmlEscape(displayKey(k)),
      actionHtml = htmlEscape(action),
      notesHtml = notes,
    })
  end

  table.sort(list, function(a, b)
    if a.key ~= b.key then return a.key < b.key end
    return a.layer < b.layer
  end)

  local rows = {}
  for _, e in ipairs(list) do
    table.insert(rows, string.format(
      '<tr data-key="%s" data-layer="%s">' ..
      '<td class="key-cell">%s</td>' ..
      '<td class="mod-cell">%s</td>' ..
      '<td class="layer-cell %s">%s</td>' ..
      '<td>%s</td>' ..
      '<td>%s</td>' ..
      '</tr>',
      htmlEscape(e.key), htmlEscape(e.layer),
      htmlEscape(displayKey(e.key)),
      e.modifierHtml,
      htmlEscape(e.layer), htmlEscape(e.layer),
      e.actionHtml,
      e.notesHtml
    ))
  end
  return string.format([[<table class="bindings">
  <thead><tr><th>Key</th><th>Modifier</th><th>Layer</th><th>Action</th><th>Notes</th></tr></thead>
  <tbody>
%s
  </tbody>
</table>]], table.concat(rows, "\n"))
end

local function renderWarnings(warnings)
  if #warnings == 0 then return "" end
  local items = {}
  for _, w in ipairs(warnings) do
    table.insert(items, string.format(
      '<li><span class="key-badge %s">%s</span> %s</li>',
      htmlEscape(w.layer), htmlEscape(displayKey(w.key)), htmlEscape(w.message)))
  end
  return string.format([[<div class="warnings">
  <h3>⚠ %d drift warning%s</h3>
  <ul>%s</ul>
</div>]], #warnings, #warnings == 1 and "" or "s", table.concat(items, ""))
end

local function renderHtml(rcmd, hyper, other, warnings)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  -- Map warnings by key for keymap dot rendering
  local warningsByKey = {}
  for _, w in ipairs(warnings or {}) do
    warningsByKey[w.key] = (warningsByKey[w.key] and warningsByKey[w.key] .. " · " or "") .. w.message
  end
  return string.format([[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>keymap</title>
<link rel="stylesheet" href="keymap.css">
</head>
<body>
<header>
  <h1>keymap</h1>
  <div class="legend">
    <span class="layer rcmd">━ rcmd (right-opt)</span>
    <span class="layer hyper">━ stepper-hyper</span>
    <span class="layer other">━ other</span>
    <span><span class="hyper-mark">◆</span> uses hyper modifier</span>
  </div>
  <div class="meta">generated %s</div>
</header>

%s

<div class="filters">
  <button data-filter="all" class="active">Show all</button>
  <button data-filter="rcmd">rcmd only</button>
  <button data-filter="hyper">hyper only</button>
  <button data-filter="other">other only</button>
  <span class="key-pill" hidden>Filtering: <span id="key-filter"></span> <button class="clear-key">✕</button></span>
</div>

%s

<h2>Bindings</h2>
%s

<script src="keymap.js"></script>
</body>
</html>
]], htmlEscape(timestamp),
    renderWarnings(warnings or {}),
    renderKeyboard(rcmd, hyper, other, warningsByKey),
    renderBindings(rcmd, hyper, other))
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.generate()
  local rcmd = readRcmd()
  local hyper, other = readHyperConfigs()
  local notes = readNotesJsonc()
  local warnings = computeWarnings(rcmd, hyper, notes)
  mergeAnnotations(rcmd, hyper, other, notes)
  local html = renderHtml(rcmd, hyper, other, warnings)
  local ok = writeFile(outputFile, html)
  if ok then
    local rcmdN, hyperN, otherN = 0, 0, 0
    for _, b in pairs(rcmd)  do if b.app   then rcmdN  = rcmdN  + 1 end end
    for _, b in pairs(hyper) do if b.type  then hyperN = hyperN + 1 end end
    for _ in pairs(other) do otherN = otherN + 1 end
    print(string.format("[keymap] Generated keymap.html (%d rcmd, %d hyper, %d other, %d warnings)",
      rcmdN, hyperN, otherN, #warnings))
  else
    print("[keymap] FAILED to write " .. tostring(outputFile))
  end
end

-- Debounced regen (path watchers can fire bursts during atomic saves)
local debounceTimer = nil
local function scheduleRegen(reason)
  if debounceTimer then debounceTimer:stop() end
  debounceTimer = hs.timer.doAfter(0.5, function()
    debounceTimer = nil
    print(string.format("[keymap] Regen triggered by: %s", reason or "?"))
    M.generate()
  end)
end

function M.init(root)
  projectRoot = root
  featureDir = root .. "features/L009-keymap"
  outputFile = featureDir .. "/keymap.html"
  M.generate()

  -- Pathwatchers — kept in M._watchers (module scope) to survive GC
  local watchSpecs = {
    {path = RCMD_PLIST,                                       reason = "rcmd plist"},
    {path = root .. "data/live-toggle-hotkeys.json",          reason = "live-toggle slot reassigned"},
    {path = root .. "data/bear-notes.jsonc",                  reason = "bear-notes.jsonc"},
    {path = root .. "data/hyper-actions.jsonc",               reason = "hyper-actions.jsonc"},
    {path = featureDir .. "/notes.jsonc",                     reason = "notes.jsonc"},
  }
  for _, spec in ipairs(watchSpecs) do
    local w = hs.pathwatcher.new(spec.path, function() scheduleRegen(spec.reason) end)
    w:start()
    table.insert(M._watchers, w)
  end

  print(string.format("[keymap] Initialized with %d pathwatchers", #M._watchers))
end

return M
