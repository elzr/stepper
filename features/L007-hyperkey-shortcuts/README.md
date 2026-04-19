# L007-hyperkey-shortcuts

> The full hyperkey system: how Caps Lock becomes a launcher/action key across three tools and three use cases.

## Contents

- [The stack](#the-stack)
- [Three use cases](#three-use-cases-in-hammerspoon) — [Bear notes](#1-bear-note-launchers) · [Live toggles](#2-live-window-toggles) · [General actions](#3-general-actions)
- [What BTT still handles](#what-bettertouchtool-still-handles) — [Known conflict pattern](#known-conflict-pattern)
- [Why JSONC](#why-jsonc)
- [Key files](#key-files)
- [How to add a new shortcut](#how-to-add-a-new-hyperkey-shortcut)
- [Origin story](#origin-story)

## The stack

| Layer | Tool | Role |
|-------|------|------|
| Physical key | **Caps Lock** | The only key the user presses (plus a letter/symbol) |
| Key remapping | **[Hyperkey app](https://hyperkey.app/)** | Remaps Caps Lock → ctrl+alt+shift+cmd (all 4 modifiers simultaneously) |
| Shortcut binding | **Hammerspoon** (stepper) | Catches hyper+key combos and runs actions |
| Shortcut binding | **BetterTouchTool** | Handles some hyper+key combos that work better outside Hammerspoon |

When the user presses Caps Lock + N, the system sees ctrl+alt+shift+cmd+N. Hammerspoon has a hotkey bound to that exact modifier combo + key, so it fires.

## Three use cases in Hammerspoon

### 1. Bear note launchers

Config: [`data/bear-notes.jsonc`](https://stepper.internal/data/bear-notes.jsonc)

Hyper + letter → open/raise a Bear note by title. Supports modifier variants:
- **Right Cmd held**: open past-week variant (e.g., previous week's days note)
- **Right Option held**: open next-week variant
- **Right Shift held**: summon note window to cursor position

Template variables (`${weekNum}`, `${weekDays}`, etc.) expand at load time from the `vars` section. Updated weekly by [L005](../L005-weekly-updater-of-Bear-shortcuts/).

Keys: N, R, D, W, T, S, M, I (and more — see [the jsonc file](https://stepper.internal/data/bear-notes.jsonc)).

### 2. Live window toggles

Config: [`data/live-toggle-hotkeys.json`](https://stepper.internal/data/live-toggle-hotkeys.json)

Hyper + reserved letter → toggle visibility of any window (not just Bear). Slots are reassignable at runtime:
- **Right Option + hyper+key**: assign the frontmost window to that slot
- **Right Shift + hyper+key**: summon window to cursor

Keys: X, Q, A, Z (reserved in [bear-notes.jsonc](https://stepper.internal/data/bear-notes.jsonc)).

### 3. General actions

Config: [`data/hyper-actions.jsonc`](https://stepper.internal/data/hyper-actions.jsonc)

Hyper + key → arbitrary action (keystroke sequence, URL, script). For shortcuts that aren't launchers. Supports two action types: `keystroke` (single key combo) and `keystroke-sequence` (chained keystrokes with delays for menu navigation).

Actions can override the default hyper modifiers with a custom `mods` field, and can be scoped to specific windows via `scope.titleContains` — scoped hotkeys are disabled by default and only activate when the focused window title matches.

Current entries — all Google Sheets insert shortcuts:

| Shortcut | Scope | Action |
|----------|-------|--------|
| **hyper+[** | global | Insert → Columns → Insert 1 column left |
| **hyper+]** | global | Insert → Columns → Insert 1 column right |
| **hyper+-** | global | Insert → Rows → Insert 1 row above |
| **hyper+=** | global | Insert → Rows → Insert 1 row below |
| **ctrl+cmd+←** | Google Sheets | Insert 1 column left |
| **ctrl+cmd+→** | Google Sheets | Insert 1 column right |
| **ctrl+cmd+↑** | Google Sheets | Insert 1 row above |
| **ctrl+cmd+↓** | Google Sheets | Insert 1 row below |

The ctrl+cmd+arrow shortcuts mirror Bear Notes' table insert shortcuts. They only activate when the focused window title contains "- Google Sheets".

### Technical note: posting keystrokes

Synthetic keystrokes must be posted directly to the frontmost app via `event:post(app)`. Posting to the global event stream doesn't work — the Hyperkey app keeps all 4 modifiers active while Caps Lock is held, so the synthetic event gets intercepted by Hammerspoon's own hyper+key bindings.

## What BetterTouchTool still handles

BTT handles some hyperkey shortcuts that work better at its level:
- Highlight colors in Bear Notes (hyper + number keys)
- Other app-specific shortcuts where BTT's per-app scoping is useful

### Known conflict pattern

BTT and Hammerspoon can clash when BTT emits a keystroke while hyper (Caps Lock) is still held. The Hyperkey app keeps all 4 modifiers active as long as Caps Lock is down, so BTT's emitted keystroke arrives with all 4 modifiers — Hammerspoon may intercept it as a hyper+key binding. **Solution**: move the shortcut from BTT to Hammerspoon (this is why hyper+[ lives here now).

## Why JSONC

Config files for hyperkey actions use JSONC (JSON with comments) rather than plain JSON. Menu-navigation sequences like `I → C → O` are cryptic without context. Inline comments sit right next to the data they describe:

```jsonc
// Google Sheets: Insert → Columns → Insert 1 column right
// Menu path: ctrl+opt+I opens Insert menu, C → Columns, O → "Insert 1 column right"
{"key": "]", "action": "keystroke-sequence", ...}
```

A `"comment"` property works but pollutes the data structure — it gets parsed, allocated, and ignored by the code. Comments are metadata *about* the config, not part of it. Our [F022](https://fleet.internal/features/F022-project-files-open-richly-in-browser/) JSONC viewer renders them beautifully with green highlighting.

## Key files

- [`data/bear-notes.jsonc`](https://stepper.internal/data/bear-notes.jsonc) — Bear note hotkey definitions + template vars
- [`data/live-toggle-hotkeys.json`](https://stepper.internal/data/live-toggle-hotkeys.json) — active window toggle slots
- [`data/hyper-actions.jsonc`](https://stepper.internal/data/hyper-actions.jsonc) — general hyperkey actions
- [`lua/bear-hud.lua`](https://stepper.internal/lua/bear-hud.lua) — all hyperkey binding logic (loads all 3 config files)

## How to add a new hyperkey shortcut

1. **Bear note?** → add to `notes` array in [`bear-notes.jsonc`](https://stepper.internal/data/bear-notes.jsonc)
2. **Window toggle?** → press Right Option + hyper+X/Q/A/Z at runtime
3. **Anything else?** → add to [`hyper-actions.jsonc`](https://stepper.internal/data/hyper-actions.jsonc):

```jsonc
// Description of what this shortcut does
// Menu path or keystroke details
{
  "key": "[",
  "action": "keystroke-sequence",
  "sequence": [
    {"key": "I", "mods": ["ctrl", "alt"]},
    {"key": "C", "delay": 0.15},
    {"key": "C", "delay": 0.15}
  ]
}
```

Then run `~/bin/hs-reload.sh`.

## Visual map

==🔵[L009-keymap](openfolder:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L009-keymap)== renders this entire stack — plus rcmd's right-opt bindings — as a live HTML keyboard diagram with per-layer underlines. ◆ marks any key bound through the hyper modifier.

## Origin story

Google Sheets has no direct keyboard shortcuts for inserting rows/columns in a specific direction. The built-in ctrl+shift+= inserts based on the current selection, which is inconsistent — sometimes it selects the full row/column, sometimes just a partial range, and the behavior changes depending on context. This inconsistency breaks muscle memory and forces you back to the menu every time.

This frustration persisted for **years**. A conversation with David Pang (founder of [SheetWiz](https://sheetwiz.app/)) confirmed that the inconsistency is a Google limitation, not a configuration problem.

The inspiration came from **Bear Notes**, which has beautifully consistent table shortcuts: ctrl+cmd+arrow to add rows/columns in any direction. That convinced me the desire for consistency was valid — the problem was Google Sheets, not my expectations.

The breakthrough was the idea of using hyper+[/] for columns and hyper+-/= for rows — memorable shortcuts mapped to the bracket and plus/minus keys. Implementing this through BetterTouchTool revealed the [Hyperkey conflict](#known-conflict-pattern) (BTT couldn't delay in keystroke sequences either), which led to building the `keystroke-sequence` action type in Hammerspoon with `event:post(app)` to bypass the modifier clash. The Bear-style ctrl+cmd+arrow shortcuts were then added as scoped alternatives for an even more natural feel.

References:
- [Claude conversation](https://claude.ai/chat/802e77d8-2da4-4704-b2c0-45cd149d4c61) that led to discovering SheetWiz
- [Email thread with David Pang](https://mail.google.com/mail/u/0/#inbox/FMfcgzQgLFfdXdhfcwbKGGhPqjHZrPdG) confirming the Google limitation
